import Foundation
import Testing
@testable import DontsToolCore

@MainActor
final class MockURLOpener: URLOpening {
    var opened: [URL] = []
    var error: Error?

    func open(_ url: URL) throws {
        if let error { throw error }
        opened.append(url)
    }
}

@Suite("WebSearchProvider")
@MainActor
struct WebSearchProviderTests {
    private func makeProvider() -> (WebSearchProvider, SettingsStore, MockURLOpener, MockPrefiller) {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let opener = MockURLOpener()
        let prefill = MockPrefiller()
        let provider = WebSearchProvider(
            settings: settings,
            usage: UsageStore(defaults: defaults),
            opener: opener,
            feedback: MockFeedback(),
            prefill: prefill
        )
        return (provider, settings, opener, prefill)
    }

    @Test func keywordOpensEncodedSearch() async throws {
        let (provider, _, opener, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "g swift concurrency",
            mode: .keyword(providerID: "web", keyword: "g", argument: "swift concurrency")
        )
        let items = await provider.search(context)
        #expect(items.count == 1)
        try await items[0].primaryAction?.run()

        let components = URLComponents(url: opener.opened[0], resolvingAgainstBaseURL: false)
        #expect(components?.host == "www.google.com")
        #expect(components?.queryItems == [URLQueryItem(name: "q", value: "swift concurrency")])
    }

    @Test func defaultEngineIsUsedForFallback() async throws {
        let (provider, settings, opener, _) = makeProvider()
        settings.setDefaultSearchEngine(.baidu)
        let items = await provider.search(SearchContext(rawQuery: "swift", mode: .global))
        #expect(items.count == 1)
        try await items[0].primaryAction?.run()
        #expect(URLComponents(url: opener.opened[0], resolvingAgainstBaseURL: false)?.host == "www.baidu.com")
    }

    @Test func emptyKeywordArgumentDoesNotOpenBrowser() async throws {
        let (provider, _, opener, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "g",
            mode: .keyword(providerID: "web", keyword: "g", argument: "")
        )
        let items = await provider.search(context)
        try await items[0].primaryAction?.run()
        #expect(opener.opened.isEmpty)
    }

    @Test func emptyQueryReturnsPrefillHint() async throws {
        let (provider, _, _, prefill) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(items.count == 1)
        try await items[0].primaryAction?.run()
        #expect(prefill.queries == ["g "])
    }

    @Test func githubKeywordUsesGithubSearch() async throws {
        let (provider, _, opener, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "gh swift",
            mode: .keyword(providerID: "web", keyword: "gh", argument: "swift")
        )
        let items = await provider.search(context)
        try await items[0].primaryAction?.run()
        #expect(URLComponents(url: opener.opened[0], resolvingAgainstBaseURL: false)?.host == "github.com")
    }

    @Test func fallbackUsesGroupWeb() async {
        let (provider, _, _, _) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "swift", mode: .global))
        #expect(items[0].group == .web)
    }

    @Test func disabledProviderReturnsNothing() async {
        let (provider, settings, _, _) = makeProvider()
        settings.setProviderEnabled("web", to: false)
        let items = await provider.search(SearchContext(rawQuery: "swift", mode: .global))
        #expect(items.isEmpty)
    }
}
