import Foundation
import Testing
@testable import DontsToolCore

@Suite("Website shortcut subpage search")
@MainActor
struct WebsiteShortcutPageProviderTests {
    private let json = """
    {"version":3,"groups":[{"keyword":"ops","name":"业务系统","items":[
      {"key":"avatar","name":"Avatar","aliases":["阿凡达","avatar system"],"environments":[
        {"key":"test","name":"测试","url":"https://test.internal/app?home=1#top","aliases":["qa"]},
        {"key":"prod","name":"生产","url":"https://prod.internal/app","aliases":["live"]}
      ],"pages":[
        {"key":"management","name":"管理页","path":"/management?tab=users#list","aliases":["managment","管理"]},
        {"key":"reports","name":"报表","path":"/reports","urls":{"prod":"https://reports.internal/production"}}
      ]},
      {"key":"billing","name":"账单系统","environments":[{"key":"production","url":"https://billing.internal"}],"pages":[{"key":"management","name":"管理页","path":"/admin"}]}
    ]}]}
    """

    private func setup(_ json: String? = nil) throws -> (WebsiteShortcutStore, WebsiteShortcutProvider, MockURLOpener) {
        let store = WebsiteShortcutStore(defaults: UserDefaults(suiteName: "dontstool.pages.tests.\(UUID())")!)
        try store.importJSON(json ?? self.json)
        let opener = MockURLOpener()
        return (store, WebsiteShortcutProvider(store: store, opener: opener, feedback: MockFeedback(), prefill: MockPrefiller()), opener)
    }

    private func search(_ query: String, _ provider: WebsiteShortcutProvider) async -> [SearchItem] {
        await provider.search(QueryParser.parse(query, routes: ToolRegistry(providers: [provider]).enabledKeywordRoutes()))
    }

    @Test func selectedSystemListsHomeAndEveryPageForEachEnvironment() async throws {
        let (_, provider, opener) = try setup()
        let items = await search("ops avatar", provider)
        #expect(items.count == 6)
        #expect(items.filter { $0.title == "Avatar · 首页" }.count == 2)
        #expect(items.filter { $0.title == "Avatar · 管理页" }.count == 2)
        #expect(items.first?.title == "Avatar · 首页")
        #expect(items.allSatisfy { $0.subtitle?.hasPrefix("https://") == true })
        #expect(Set(items.map(\.canonicalKey)).count == 6)
        #expect(opener.opened.isEmpty)
    }

    @Test(arguments: ["ops avatar management", "ops avatar managment", "ops avatar 管理", "ops avatar 管理页", "ops AVATAR MANAGEMENT", "ops ＡＶＡＴＡＲ ｍａｎａｇｅｍｅｎｔ", "ops ava manag", "ops avatar system management"])
    func pageSelectorsMatchKeyAliasNameAndTypingPrefix(_ query: String) async throws {
        let (_, provider, _) = try setup()
        let items = await search(query, provider)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.title == "Avatar · 管理页" })
        #expect(Set(items.compactMap(\.subtitle)) == ["https://test.internal/management?tab=users#list", "https://prod.internal/management?tab=users#list"])
    }

    @Test(arguments: ["ops avatar management prod", "ops avatar management live", "ops avatar management 生产", "ops avatar management pro", "ops avatar 管理页 PROD"])
    func pageEnvironmentSuffixSelectsOnlyThatAddress(_ query: String) async throws {
        let (_, provider, opener) = try setup()
        let items = await search(query, provider)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.title == "Avatar · 管理页")
        #expect(item.subtitle == "https://prod.internal/management?tab=users#list")
        #expect(item.badge?.text == "PROD")
        #expect(item.badge?.tint == .red)
        #expect(opener.opened.isEmpty)
        try await item.primaryAction?.run()
        #expect(opener.opened.map(\.absoluteString) == ["https://prod.internal/management?tab=users#list"])
    }

    @Test(arguments: ["ops avatar prod", "ops prod avatar", "ops avatar home prod", "ops avatar 首页 prod"])
    func environmentOnlyOrExplicitHomeRetainsHomepage(_ query: String) async throws {
        let (_, provider, _) = try setup()
        let items = await search(query, provider)
        #expect(items.count == 1)
        #expect(items.first?.title == "Avatar · 首页")
        #expect(items.first?.subtitle == "https://prod.internal/app")
        #expect(items.first?.canonicalKey == "website-environment:ops:avatar:prod")
    }

    @Test func pageOverrideUsesItsSelectedEnvironment() async throws {
        let (_, provider, _) = try setup()
        #expect(await search("ops avatar reports prod", provider).first?.subtitle == "https://reports.internal/production")
        #expect(await search("ops avatar reports test", provider).first?.subtitle == "https://test.internal/reports")
    }

    @Test(arguments: ["ops avatar missing", "ops avatar management staging", "ops avatar reports billing", "ops avatar missing prod", "ops billing management test"])
    func unknownPageAndUnavailableEnvironmentNeverFallBack(_ query: String) async throws {
        let (_, provider, _) = try setup()
        #expect(await search(query, provider).isEmpty)
    }

    @Test func wholeSystemAliasWinsOverPageAndEnvironmentParsing() async throws {
        let (store, provider, _) = try setup()
        var config = store.configuration
        config.groups[0].items.append(.init(key: "tool", name: "专用工具", url: "https://tools.internal", aliases: ["avatar management prod"]))
        try store.save(config)
        let items = await search("ops avatar management prod", provider)
        #expect(items.count == 1)
        #expect(items.first?.title == "专用工具")
    }

    @Test func unrelatedSystemPrefixesDoNotStealSelectedSystemPageOrEnvironment() async throws {
        let (store, provider, _) = try setup()
        var config = store.configuration
        config.groups[0].items.append(.init(key: "other", name: "其他", url: "https://other.internal", aliases: ["avatar management plus", "avatar prod suite"]))
        config.groups[0].items[1].environments[0].aliases = ["avatar"]
        try store.save(config)
        let pages = await search("ops avatar management prod", provider)
        #expect(pages.count == 1)
        #expect(pages.first?.title == "Avatar · 管理页")
        let homes = await search("ops avatar prod", provider)
        #expect(homes.count == 1)
        #expect(homes.first?.subtitle == "https://prod.internal/app")
    }

    @Test func exactPageWinsOverEnvironmentWithSameSelector() async throws {
        let (_, provider, _) = try setup(json.replacingOccurrences(of: "\"key\":\"management\"", with: "\"key\":\"test\""))
        let items = await search("ops avatar test", provider)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.title == "Avatar · 管理页" })
        #expect(await search("ops avatar test prod", provider).first?.subtitle == "https://prod.internal/management?tab=users#list")
    }

    @Test func stablePageIdentitySurvivesOrderAndDisplayNameChanges() async throws {
        let (store, provider, _) = try setup()
        let before = try #require(await search("ops avatar management prod", provider).first)
        var config = store.configuration
        config.groups[0].items[0].environments.reverse()
        try store.importJSON(config.json().replacingOccurrences(of: "管理页", with: "管理中心"))
        let after = try #require(await search("ops avatar management prod", provider).first)
        #expect(before.canonicalKey == after.canonicalKey)
        #expect(after.title == "Avatar · 管理中心")
    }

    @Test func coordinatorKeepsHomepageAheadOfAlphabeticallyEarlierPage() async throws {
        let (_, provider, _) = try setup()
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [provider]))
        var last: SearchCoordinator.Update?
        coordinator.onUpdate = { last = $0 }
        coordinator.submit("ops avatar")
        await coordinator.waitForPendingSearch()
        #expect(last?.items.first?.title == "Avatar · 首页")
    }

    @Test func singleAddressPagesKeepLegacyHomepageIdentityAndOpenResolvedURL() async throws {
        let (_, provider, opener) = try setup("""
        {"version":3,"groups":[{"keyword":"ops","name":"系统","items":[{"key":"docs:service","name":"文档","url":"https://docs.internal/base","pages":[{"key":"guide","name":"指南","path":"https://help.internal/guide"}]}]}]}
        """)
        let items = await search("ops docs:service", provider)
        #expect(items.count == 2)
        #expect(items.first?.canonicalKey == "website:ops:docs:service")
        #expect(items.first?.subtitle == "https://docs.internal/base")
        let page = try #require(await search("ops docs:service guide", provider).first)
        #expect(page.canonicalKey != items.first?.canonicalKey)
        #expect(page.canonicalKey.contains("docs%3Aservice"))
        #expect(page.badge == nil)
        try await page.primaryAction?.run()
        #expect(opener.opened.map(\.absoluteString) == ["https://help.internal/guide"])
        #expect(await search("ops docs:service guide prod", provider).isEmpty)
    }

    @Test func globalSystemLookupStillIncludesItsPages() async throws {
        let (_, provider, _) = try setup()
        let items = await search("avatar", provider)
        #expect(items.contains { $0.title == "Avatar · 首页" })
        #expect(items.contains { $0.title == "Avatar · 管理页" })
    }

    @Test func disabledOrCancelledPageActionCannotOpenAndCapturedURLIsStable() async throws {
        let (store, provider, opener) = try setup()
        let item = try #require(await search("ops avatar management prod", provider).first)
        provider.isEnabled = false
        try await item.primaryAction?.run()
        #expect(opener.opened.isEmpty)
        provider.isEnabled = true
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await item.primaryAction?.run()
        }
        try await task.value
        #expect(opener.opened.isEmpty)
        var config = store.configuration
        config.groups[0].items[0].environments[1].url = "https://replacement.internal"
        try store.save(config)
        try await item.primaryAction?.run()
        #expect(opener.opened.map(\.absoluteString) == ["https://prod.internal/management?tab=users#list"])
    }
}
