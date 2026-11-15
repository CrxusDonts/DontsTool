import Foundation
import Testing
@testable import DontsToolCore

@Suite("Website shortcuts")
@MainActor
struct WebsiteShortcutsTests {
    private func fixture() throws -> WebsiteShortcutConfiguration {
        try WebsiteShortcutConfiguration.decode("""
        {"version":1,"groups":[{"keyword":"gh","name":"代码仓库","items":[
          {"key":"a","name":"项目 A","url":"https://git.company.example/team/a?tab=code#readme","aliases":["订单服务"]},
          {"key":"ab","name":"项目 AB","url":"http://git.internal:8080/team/ab"},
          {"key":"b","name":"项目 B","url":"https://git.company.example/team/b"}
        ]}]}
        """)
    }

    private func store() -> WebsiteShortcutStore {
        WebsiteShortcutStore(defaults: UserDefaults(suiteName: "dontstool.shortcuts.tests.\(UUID())")!)
    }

    private func provider(_ store: WebsiteShortcutStore, opener: MockURLOpener = MockURLOpener()) -> WebsiteShortcutProvider {
        WebsiteShortcutProvider(store: store, opener: opener, feedback: MockFeedback(), prefill: MockPrefiller())
    }

    @Test func jsonRoundTripsWithoutLosingAliasesOrURLs() throws {
        let config = try fixture()
        #expect(config.groups[0].items[1].aliases.isEmpty)
        #expect(try WebsiteShortcutConfiguration.decode(config.json()) == config)
    }

    @Test(arguments: [
        "{\"version\":4,\"groups\":[]}",
        "{\"version\":1,\"groups\":[],\"gropus\":[]}",
        "{\"version\":1,\"groups\":[{\"keyword\":\"json\",\"name\":\"x\",\"items\":[]}]}",
        "{\"version\":1,\"groups\":[{\"keyword\":\"two words\",\"name\":\"x\",\"items\":[]}]}",
        "{\"version\":1,\"groups\":[{\"keyword\":\"gh\",\"name\":\"x\",\"items\":[]},{\"keyword\":\"GH\",\"name\":\"y\",\"items\":[]}]}",
        "{\"version\":1,\"groups\":[{\"keyword\":\"gh\",\"name\":\"x\",\"items\":[{\"key\":\"a\",\"name\":\"A\",\"url\":\"javascript:alert(1)\"}]}]}",
        "{\"version\":1,\"groups\":[{\"keyword\":\"gh\",\"name\":\"x\",\"items\":[{\"key\":\"a\",\"name\":\"A\",\"url\":\"https://user:pass@internal/path\"}]}]}",
        "{\"version\":1,\"groups\":[{\"keyword\":\"gh\",\"name\":\"x\",\"items\":[{\"key\":\"a\",\"name\":\"A\",\"url\":\"https://internal/a\"},{\"key\":\"A\",\"name\":\"B\",\"url\":\"https://internal/b\"}]}]}",
        "{\"version\":1,\"groups\":[{\"keyword\":\"gh\",\"name\":\"x\",\"items\":[{\"key\":\"a\",\"name\":\"A\",\"url\":\"https://internal/a\",\"aliases\":[\"订单\"]},{\"key\":\"b\",\"name\":\"B\",\"url\":\"https://internal/b\",\"aliases\":[\"订单\"]}]}]}",
        "{\"version\":1,\"groups\":[{\"keyword\":\"gh\",\"name\":\"x\",\"items\":[{\"key\":\"a\",\"name\":\"A\",\"url\":\"https://internal/a\",\"alises\":[\"A\"]}]}]}"
    ])
    func invalidConfigurationsAreRejected(_ json: String) {
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(json) }
    }

    @Test func savingIsAtomicAndPersistsAcrossRelaunch() throws {
        let defaults = UserDefaults(suiteName: "dontstool.shortcuts.tests.\(UUID())")!
        let store = WebsiteShortcutStore(defaults: defaults)
        let config = try fixture()
        try store.save(config)
        #expect(throws: (any Error).self) { try store.importJSON("{broken}") }
        #expect(store.configuration == config)
        #expect(WebsiteShortcutStore(defaults: defaults).configuration == config)
    }

    @Test func malformedStoredDataIsPreservedUntilExplicitSave() throws {
        let defaults = UserDefaults(suiteName: "dontstool.shortcuts.tests.\(UUID())")!
        defaults.set(Data("{broken}".utf8), forKey: "dontstool.websiteShortcuts")
        let store = WebsiteShortcutStore(defaults: defaults)
        #expect(store.loadError != nil)
        #expect(store.configuration.groups.isEmpty)
        #expect(store.editableJSON == "{broken}")
        #expect(defaults.data(forKey: "dontstool.websiteShortcuts") == Data("{broken}".utf8))
    }

    @Test func prefixAndAliasSearchDoNotOpenUntilExecuted() async throws {
        let store = store(); try store.save(fixture())
        let opener = MockURLOpener(); let provider = provider(store, opener: opener)
        let context = QueryParser.parse("GH 订单服务", routes: ToolRegistry(providers: [provider]).enabledKeywordRoutes())
        let items = await provider.search(context)
        #expect(items.map(\.title) == ["项目 A"])
        #expect(opener.opened.isEmpty)
        try await #require(items.first).primaryAction?.run()
        #expect(opener.opened.map(\.absoluteString) == ["https://git.company.example/team/a?tab=code#readme"])
    }

    @Test func exactKeyRanksBeforePrefixMatch() async throws {
        let store = store(); try store.save(fixture())
        let provider = provider(store)
        let items = await provider.search(QueryParser.parse("gh a", routes: ToolRegistry(providers: [provider]).enabledKeywordRoutes()))
        #expect(items.first?.title == "项目 A")
        #expect(items.contains { $0.title == "项目 AB" })
    }

    @Test func exactKeyWinsOverAnotherItemsExactDisplayName() async throws {
        let store = store()
        try store.save(.init(groups: [.init(keyword: "gh", name: "仓库", items: [
            .init(key: "a", name: "Zebra service", url: "https://internal/z"),
            .init(key: "b", name: "A", url: "https://internal/a")
        ])]))
        let shortcuts = provider(store)
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [shortcuts]))
        var result: SearchCoordinator.Update?
        coordinator.onUpdate = { result = $0 }
        coordinator.submit("gh a")
        await coordinator.waitForPendingSearch()
        #expect(result?.items.first?.title == "Zebra service")
    }

    @Test func diacriticVariantDoesNotCompeteWithExactKey() async throws {
        let store = store()
        try store.save(.init(groups: [.init(keyword: "gh", name: "仓库", items: [
            .init(key: "a", name: "Zebra", url: "https://internal/z"),
            .init(key: "á", name: "Alpha", url: "https://internal/a")
        ])]))
        let shortcuts = provider(store)
        let result = await shortcuts.search(QueryParser.parse("gh a", routes: ToolRegistry(providers: [shortcuts]).enabledKeywordRoutes()))
        #expect(result.first?.title == "Zebra")
    }

    @Test func changedQuerySelectsTopMatchButRefreshPreservesUserSelection() async throws {
        let store = store(); try store.save(fixture())
        let opener = MockURLOpener()
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [provider(store, opener: opener)]))
        let panel = LauncherPanelModel(coordinator: coordinator, hotKeyDisplay: "test")
        panel.submit("gh")
        await coordinator.waitForPendingSearch()
        panel.select(index: 1)
        panel.submit("gh")
        await coordinator.waitForPendingSearch()
        #expect(panel.selectedIndex == 1)
        panel.submit("gh a")
        await coordinator.waitForPendingSearch()
        #expect(panel.selectedIndex == 0)
        #expect(panel.selectedItem?.title == "项目 A")
        try await #require(panel.selectedItem).primaryAction?.run()
        #expect(opener.opened.first?.absoluteString == "https://git.company.example/team/a?tab=code#readme")
    }

    @Test func explicitNullAliasesAreNotSilentlyDropped() {
        #expect(throws: (any Error).self) {
            try WebsiteShortcutConfiguration.decode("""
            {"version":1,"groups":[{"keyword":"gh","name":"仓库","items":[{"key":"a","name":"A","url":"https://internal/a","aliases":null}]}]}
            """)
        }
    }

    @Test func noMatchDoesNotFallBackToPublicSearch() async throws {
        let store = store(); try store.save(fixture())
        let shortcuts = provider(store)
        let web = MockProvider(id: "web", keywords: ["gh"], priority: 150)
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [web, shortcuts]))
        var updates: [SearchCoordinator.Update] = []
        coordinator.onUpdate = { updates.append($0) }
        coordinator.submit("gh private-missing-project")
        await coordinator.waitForPendingSearch()
        #expect(web.receivedQueries.isEmpty)
        #expect(updates.last?.items.isEmpty == true)
        #expect(updates.last?.status == .message("没有匹配的网址，请检查简称或在设置中添加"))
    }

    @Test func routeUpdatesImmediatelyAfterConfigurationChanges() throws {
        let store = store(); let registry = ToolRegistry(providers: [provider(store)])
        #expect(registry.enabledKeywordRoutes()["gh"] == nil)
        try store.save(fixture())
        #expect(registry.enabledKeywordRoutes()["gh"]?.providerID == "website")
        try store.save(.init(version: 1, groups: []))
        #expect(registry.enabledKeywordRoutes()["gh"] == nil)
    }

    @Test func scopedListIsNotTruncatedByWebFallbackCap() async throws {
        let store = store()
        let entries = (0..<20).map { WebsiteShortcut(key: "p\($0)", name: "项目 \($0)", url: "https://internal/p\($0)") }
        try store.save(.init(version: 1, groups: [.init(keyword: "gh", name: "仓库", items: entries)]))
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [provider(store)]))
        var last: SearchCoordinator.Update?
        coordinator.onUpdate = { last = $0 }
        coordinator.submit("gh")
        await coordinator.waitForPendingSearch()
        #expect(last?.items.count == 20)
    }
}


@Suite("Website shortcut environments")
@MainActor
struct WebsiteShortcutEnvironmentTests {
    private let environmentJSON = """
    {"version":2,"groups":[{"keyword":"ops","name":"业务系统","items":[
      {"key":"order","name":"订单系统","aliases":["订单"],"environments":[
        {"key":"test","name":"测试","url":"http://test.internal:8080/orders?next=%2Fdetail#top","aliases":["qa"]},
        {"key":"prod","name":"生产","url":"https://production.internal/orders","aliases":["live"]}
      ]},
      {"key":"billing","name":"账单系统","aliases":["账单"],"environments":[
        {"key":"test","url":"http://test.internal/billing"}
      ]}
    ]}]}
    """

    private func setup() throws -> (WebsiteShortcutStore, WebsiteShortcutProvider, MockURLOpener) {
        let store = WebsiteShortcutStore(defaults: UserDefaults(suiteName: "dontstool.environments.tests.\(UUID())")!)
        try store.importJSON(environmentJSON)
        let opener = MockURLOpener()
        return (store, WebsiteShortcutProvider(store: store, opener: opener, feedback: MockFeedback(), prefill: MockPrefiller()), opener)
    }

    private func search(_ query: String, using provider: WebsiteShortcutProvider) async -> [SearchItem] {
        await provider.search(QueryParser.parse(query, routes: ToolRegistry(providers: [provider]).enabledKeywordRoutes()))
    }

    @Test func versionTwoEnvironmentsRoundTripWithoutLosingFullURLs() throws {
        let config = try WebsiteShortcutConfiguration.decode(environmentJSON)
        #expect(config.itemCount == 2)
        #expect(try WebsiteShortcutConfiguration.decode(config.json()) == config)
    }

    @Test func systemSearchListsEachEnvironmentWithoutOpening() async throws {
        let (_, provider, opener) = try setup()
        let items = await search("ops 订单", using: provider)
        #expect(items.count == 2)
        #expect(Set(items.map(\.canonicalKey)).count == 2)
        #expect(opener.opened.isEmpty)
        let test = try #require(items.first { $0.subtitle?.contains("test.internal") == true })
        try await test.primaryAction?.run()
        #expect(opener.opened.map(\.absoluteString) == ["http://test.internal:8080/orders?next=%2Fdetail#top"])
    }

    @Test(arguments: ["ops 订单 test", "ops test 订单", "ops 订单 QA", "ops 订单 测试", "ops ＴＥＳＴ 订单"])
    func environmentTokensFilterByKeyAliasAndName(_ query: String) async throws {
        let (_, provider, _) = try setup()
        let items = await search(query, using: provider)
        #expect(items.count == 1)
        #expect(items.first?.subtitle?.contains("test.internal:8080/orders") == true)
    }

    @Test func unavailableEnvironmentDoesNotFallBackToAnotherAddress() async throws {
        let (_, provider, _) = try setup()
        #expect(await search("ops 账单 prod", using: provider).isEmpty)
        let production = await search("ops prod", using: provider)
        #expect(production.count == 1)
        #expect(production.first?.subtitle?.contains("production.internal/orders") == true)
    }

    @Test func exactSystemAliasWinsBeforeEnvironmentSuffixParsing() async throws {
        let (store, provider, _) = try setup()
        var configuration = store.configuration
        configuration.groups[0].items.append(.init(key: "order-test", name: "专用测试工具", url: "https://tools.internal/", aliases: ["订单 test"]))
        try store.save(configuration)
        let results = await search("ops 订单 test", using: provider)
        #expect(results.first?.title == "专用测试工具")
        #expect(results.first?.subtitle?.contains("tools.internal") == true)
    }

    @Test func disabledProviderCannotExecuteAStaleResult() async throws {
        let (_, provider, opener) = try setup()
        let item = try #require(await search("ops 订单 prod", using: provider).first)
        provider.isEnabled = false
        try await item.primaryAction?.run()
        #expect(opener.opened.isEmpty)
    }

    @Test func cancelledActionCannotOpenAnEnvironment() async throws {
        let (_, provider, opener) = try setup()
        let item = try #require(await search("ops 订单 prod", using: provider).first)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await item.primaryAction?.run()
        }
        try await task.value
        #expect(opener.opened.isEmpty)
    }

    @Test(arguments: [
        "{\"key\":\"test\",\"url\":\"https://internal\",\"alises\":[]}",
        "{\"key\":\"test\",\"url\":\"https://internal\",\"aliases\":null}",
        "{\"key\":\"test\",\"name\":null,\"url\":\"https://internal\"}",
        "{\"key\":\"test\",\"url\":\"https://user:pass@internal\"}",
        "{\"key\":\"test\",\"url\":\"file:///tmp/a\"}",
        "{\"key\":\"test\",\"url\":\"https://internal\",\"aliases\":[\"ＴＥＳＴ\"]}"
    ])
    func malformedEnvironmentEntriesAreRejected(_ environment: String) {
        let json = "{\"version\":2,\"groups\":[{\"keyword\":\"ops\",\"name\":\"系统\",\"items\":[{\"key\":\"order\",\"name\":\"订单\",\"environments\":[\(environment)]}]}]}"
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(json) }
    }

    @Test func environmentPrefixFiltersProductionInsteadOfDroppingTheQualifier() async throws {
        let (_, provider, _) = try setup()
        let suffix = await search("ops 订单 pro", using: provider)
        let prefix = await search("ops pro 订单", using: provider)
        #expect(suffix.count == 1)
        #expect(suffix.first?.badge?.text == "PROD")
        #expect(prefix.map(\.canonicalKey) == suffix.map(\.canonicalKey))
        #expect(await search("ops 账单 pro", using: provider).isEmpty)
    }

    @Test func exactEnvironmentKeyWinsOverAnotherEnvironmentsDisplayName() async throws {
        let (store, provider, _) = try setup()
        var config = store.configuration
        config.groups[0].items[0].environments[0].name = "prod"
        try store.save(config)
        let result = await search("ops 订单 prod", using: provider)
        #expect(result.count == 1)
        #expect(result.first?.badge?.text == "PROD")
        #expect(result.first?.subtitle?.contains("production.internal") == true)
    }

    @Test func environmentKeysAreNormalizedAndRestrictedToCommandTokens() throws {
        let config = try WebsiteShortcutConfiguration.decode(environmentJSON.replacingOccurrences(of: "\"key\":\"test\"", with: "\"key\":\" TEST \""))
        #expect(config.groups[0].items[0].environments[0].key == "test")
        for invalidKey in ["1test", "测试", "bad:key", String(repeating: "a", count: 33)] {
            let invalid = environmentJSON.replacingOccurrences(of: "\"key\":\"test\"", with: "\"key\":\"\(invalidKey)\"")
            #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(invalid) }
        }
    }

    @Test func resolvedAddressCountAndDefaultEnvironmentNameSurviveRoundTrip() throws {
        let config = try WebsiteShortcutConfiguration.decode(environmentJSON)
        #expect(config.addressCount == 3)
        #expect(config.groups[0].items[1].environments[0].name == "TEST")
        #expect(WebsiteShortcutConfiguration.empty.version == 3)
        #expect(try WebsiteShortcutConfiguration.decode(config.json()).addressCount == 3)
    }

    @Test func resultsExposeIndependentEnvironmentBadgesAndStableIdentities() async throws {
        let (store, provider, _) = try setup()
        let items = await search("ops 订单", using: provider)
        #expect(items.map { $0.badge?.text } == ["TEST", "PROD"])
        #expect(items.map { $0.badge?.tint } == [.blue, .red])
        var config = store.configuration
        config.groups[0].items[0].environments.reverse()
        try store.save(config)
        let reordered = await search("ops 订单", using: provider)
        #expect(Set(reordered.map(\.canonicalKey)) == Set(items.map(\.canonicalKey)))
        #expect(await search("ops 订单 staging", using: provider).isEmpty)
    }

    @Test func actionKeepsTheExplicitAddressEvenAfterConfigurationChanges() async throws {
        let (store, provider, opener) = try setup()
        let result = try #require(await search("ops 订单 prod", using: provider).first)
        var config = store.configuration
        config.groups[0].items[0].environments[1].url = "https://replacement.internal/"
        try store.save(config)
        try await result.primaryAction?.run()
        #expect(opener.opened.map(\.absoluteString) == ["https://production.internal/orders"])
    }

    @Test(arguments: [
        "\"url\":\"https://internal\",\"environments\":[{\"key\":\"test\",\"url\":\"https://test.internal\"}]",
        "\"environments\":[]",
        "\"environments\":null",
        "\"url\":null,\"environments\":[{\"key\":\"test\",\"url\":\"https://test.internal\"}]",
        "\"environments\":[{\"key\":\"test\",\"url\":\"https://test.internal\"},{\"key\":\"TEST\",\"url\":\"https://other.internal\"}]",
        "\"environments\":[{\"key\":\"test\",\"url\":\"https://test.internal\",\"aliases\":[\"qa\"]},{\"key\":\"prod\",\"url\":\"https://other.internal\",\"aliases\":[\"ＱＡ\"]}]"
    ])
    func addressModesAndEnvironmentIdentitiesCannotBeAmbiguous(_ fields: String) {
        let json = "{\"version\":2,\"groups\":[{\"keyword\":\"ops\",\"name\":\"系统\",\"items\":[{\"key\":\"order\",\"name\":\"订单\",\(fields)}]}]}"
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(json) }
    }

    @Test func eachSystemRejectsMoreThanThirtyTwoEnvironments() {
        let environments = (0..<33).map { WebsiteShortcutEnvironment(key: "e\($0)", url: "https://internal") }
        let config = WebsiteShortcutConfiguration(groups: [.init(keyword: "ops", name: "系统", items: [.init(key: "order", name: "订单", environments: environments)])])
        #expect(throws: (any Error).self) { try config.validated() }
    }

    @Test func addressLimitCountsEveryEnvironmentRatherThanOnlySystems() throws {
        let environments = (0..<32).map { WebsiteShortcutEnvironment(key: "e\($0)", url: "https://internal") }
        var items = (0..<156).map { WebsiteShortcut(key: "p\($0)", name: "项目", environments: environments) }
        items.append(.init(key: "last", name: "末项", environments: Array(environments.prefix(8))))
        var config = WebsiteShortcutConfiguration(groups: [.init(keyword: "ops", name: "系统", items: items)])
        #expect(try config.validated().addressCount == 5000)
        config.groups[0].items[156].environments.append(environments[8])
        #expect(throws: (any Error).self) { try config.validated() }
    }

    @Test func environmentMatchPriorityIsResolvedWithinTheMatchedSystem() async throws {
        let (store, provider, _) = try setup()
        var config = store.configuration
        config.groups[0].items[0].environments[1].key = "production"
        config.groups[0].items[1].environments[0].key = "prod"
        try store.save(config)
        let result = await search("ops 订单 prod", using: provider)
        #expect(result.count == 1)
        #expect(result.first?.badge?.text == "PRODUCTION")
        #expect(result.first?.subtitle?.contains("production.internal/orders") == true)
        #expect(await search("ops 账单 production", using: provider).isEmpty)
    }

    @Test func environmentAliasesCannotCollideAfterWhitespaceNormalization() {
        let json = environmentJSON.replacingOccurrences(of: "\"qa\"", with: "\"qa env\"")
            .replacingOccurrences(of: "\"live\"", with: "\"qa  env\"")
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(json) }
    }

    @Test func versionOneRequiresExplicitUpgradeBeforeEnvironmentImport() {
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(environmentJSON.replacingOccurrences(of: "\"version\":2", with: "\"version\":1")) }
    }
}
