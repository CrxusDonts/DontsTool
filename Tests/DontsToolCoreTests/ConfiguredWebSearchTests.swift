import Foundation
import Testing
@testable import DontsToolCore

@Suite("Configured web search routing")
@MainActor
struct ConfiguredWebSearchTests {
    @Test func customKeywordIsAvailableImmediatelyAndOpensEncodedQuery() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try fixture.addCompanyEngine()
        let context = QueryParser.parse("wiki 发布流程 + &", routes: fixture.registry.enabledKeywordRoutes())
        #expect(context.mode == .keyword(providerID: "web", keyword: "wiki", argument: "发布流程 + &"))
        let item = try #require(await fixture.provider.search(context).first)
        try await item.primaryAction?.run()
        let components = try #require(fixture.opener.opened.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(components.host == "docs.company.example")
        #expect(components.queryItems == [URLQueryItem(name: "term", value: "发布流程 + &"), URLQueryItem(name: "scope", value: "all")])
    }

    @Test func customDefaultAndEditedBuiltInUseConfiguredTemplates() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try fixture.addCompanyEngine()
        let fallback = try #require(await fixture.provider.search(SearchContext(rawQuery: "release", mode: .global)).last)
        try await fallback.primaryAction?.run()
        #expect(fixture.opener.opened.last?.host == "docs.company.example")
        var config = fixture.engines.configuration
        config.engines[0].urlTemplate = "https://search.company.example/find?q={query}"
        try fixture.engines.save(config)
        let context = QueryParser.parse("g swift", routes: fixture.registry.enabledKeywordRoutes())
        let item = try #require(await fixture.provider.search(context).first)
        try await item.primaryAction?.run()
        #expect(fixture.opener.opened.last?.host == "search.company.example")
    }

    @Test func engineNameAndBareKeywordLeadToPrefillWithoutOpeningBrowser() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try fixture.addCompanyEngine()
        for query in ["公司文档", "wiki"] {
            let context = QueryParser.parse(query, routes: fixture.registry.enabledKeywordRoutes())
            let items = await fixture.provider.search(context)
            let entry = try #require(items.first { $0.keyword == "wiki" })
            #expect(entry.title.contains("公司文档"))
            #expect(entry.primaryAction?.presentation == .keepPanelOpen)
            try await entry.primaryAction?.run()
        }
        #expect(fixture.prefill.queries == ["wiki ", "wiki "])
        #expect(fixture.opener.opened.isEmpty)
    }

    @Test func disablingOrRenamingEngineUpdatesKeywordRoutes() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try fixture.addCompanyEngine()
        var config = fixture.engines.configuration
        let index = try #require(config.engines.firstIndex { $0.id == "company" })
        config.engines[index].keyword = "docs"
        try fixture.engines.save(config)
        #expect(fixture.registry.enabledKeywordRoutes()["wiki"] == nil)
        #expect(fixture.registry.enabledKeywordRoutes()["docs"]?.providerID == "web")
        config.defaultEngineID = "google"
        config.engines[index].isEnabled = false
        try fixture.engines.save(config)
        #expect(fixture.registry.enabledKeywordRoutes()["docs"] == nil)
    }

    @Test func shadowedDefaultOffersAnAvailableEntryWithoutChangingDefaultFallback() async throws {
        let fixture = Fixture(unavailableKeywords: ["gh"])
        defer { fixture.close() }
        var config = fixture.engines.configuration
        config.defaultEngineID = "github"
        try fixture.engines.save(config)
        let entry = try #require(await fixture.provider.search(SearchContext(rawQuery: "", mode: .global)).first)
        try await entry.primaryAction?.run()
        #expect(fixture.prefill.queries == ["g "])
        let fallback = try #require(await fixture.provider.search(SearchContext(rawQuery: "release", mode: .global)).last)
        try await fallback.primaryAction?.run()
        #expect(fixture.opener.opened.last?.host == "github.com")
    }
}

@MainActor private struct Fixture {
    let engines: SearchEngineStore
    let provider: WebSearchProvider
    let registry: ToolRegistry
    let opener = MockURLOpener()
    let prefill = MockPrefiller()
    private let defaults: UserDefaults
    private let name = "dontstool.web.configured.\(UUID().uuidString)"

    init(unavailableKeywords: Set<String> = []) {
        defaults = UserDefaults(suiteName: name)!
        engines = SearchEngineStore(defaults: defaults)
        provider = WebSearchProvider(settings: SettingsStore(defaults: defaults), engines: engines, usage: UsageStore(defaults: defaults),
            opener: opener, feedback: MockFeedback(), prefill: prefill, unavailableKeywords: { unavailableKeywords })
        registry = ToolRegistry(providers: [provider])
    }

    func addCompanyEngine() throws {
        var config = engines.configuration
        config.engines.append(SearchEngineDefinition(id: "company", name: "公司文档", keyword: "wiki",
            urlTemplate: "https://docs.company.example/search?term={query}&scope=all"))
        config.defaultEngineID = "company"
        try engines.save(config)
    }

    func close() { defaults.removePersistentDomain(forName: name) }
}
