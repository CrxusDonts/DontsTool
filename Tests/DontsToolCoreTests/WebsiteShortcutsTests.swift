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
        "{\"version\":2,\"groups\":[]}",
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
