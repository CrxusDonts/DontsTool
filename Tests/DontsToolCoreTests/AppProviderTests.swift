import Foundation
import Testing
@testable import DontsToolCore

@MainActor
final class MockAppLauncher: AppLaunching {
    var openedApplications: [URL] = []
    var openedFiles: [URL] = []
    var revealed: [URL] = []
    var quitRequests: [URL] = []
    var error: Error?
    var quitSucceeds = true

    func openApplication(at url: URL) async throws {
        if let error { throw error }
        openedApplications.append(url)
    }

    func openFile(at url: URL) throws {
        if let error { throw error }
        openedFiles.append(url)
    }

    func revealInFinder(_ url: URL) {
        revealed.append(url)
    }

    func quitApplication(at url: URL) -> Bool {
        quitRequests.append(url)
        return quitSucceeds
    }
}

@MainActor
final class MockFeedback: FeedbackProviding {
    var messages: [String] = []
    func show(_ message: String) { messages.append(message) }
}

@Suite("AppProvider")
@MainActor
struct AppProviderTests {
    private func makeEntry(_ name: String, path: String) -> AppEntry {
        AppEntry(
            id: path,
            displayName: name,
            bundleID: nil,
            url: URL(fileURLWithPath: path),
            modifiedAt: nil
        )
    }

    @Test(arguments: ["weixin", "wei xin", "wx"])
    func matchesChineseNameByPinyin(query: String) async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("微信", path: "/Applications/WeChat.app")])
        let provider = AppProvider(
            index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "zh"),
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: query, mode: .global))
        #expect(items.map(\.title) == ["微信"])
    }

    @Test(arguments: [
        ("网易云音乐", "wangyiyunyinyue"),
        ("网易云音乐", "wyyyy"),
        ("QQ音乐", "qqyinyue"),
        ("QQ音乐", "qqyy"),
        ("绿联", "lvlian")
    ])
    func matchesWordAwarePinyinAndMixedLatinInitials(name: String, query: String) async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry(name, path: "/Applications/Music.app")])
        let provider = AppProvider(
            index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "zh"),
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: query, mode: .global))
        #expect(items.map(\.title) == [name])
    }

    @Test(arguments: ["vsc", "vscode", "vs code"])
    func matchesEnglishWordAbbreviation(query: String) async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Visual Studio Code", path: "/Applications/Visual Studio Code.app")])
        let provider = AppProvider(
            index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "en"),
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: query, mode: .global))
        #expect(items.map(\.title) == ["Visual Studio Code"])
    }

    @Test func matchesApplicationFilenameWhenDisplayNameIsLocalized() async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("终端", path: "/System/Applications/Utilities/Terminal.app")])
        let provider = AppProvider(
            index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "zh"),
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "terminal", mode: .global))
        #expect(items.map(\.title) == ["终端"])
    }

    @Test func englishInitialsRankAboveLooseSubsequenceMatches() async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([
            makeEntry("Vasculum", path: "/Applications/Vasculum.app"),
            makeEntry("Visual Studio Code", path: "/Applications/Visual Studio Code.app")
        ])
        let provider = AppProvider(
            index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "en"),
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "vsc", mode: .global))
        #expect(items.map(\.title) == ["Visual Studio Code", "Vasculum"])
    }

    @Test func literalNameRanksAboveFrequentlyUsedPinyinMatch() async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([
            makeEntry("微信", path: "/Applications/WeChat.app"),
            makeEntry("My Weixin Utility", path: "/Applications/My Weixin Utility.app")
        ])
        let usage = UsageStore(defaults: defaults)
        for _ in 0..<100 { usage.recordUse(of: "/Applications/WeChat.app") }
        let provider = AppProvider(
            index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "en"),
            usage: usage,
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "weixin", mode: .global))
        #expect(items.map(\.title) == ["My Weixin Utility", "微信"])
    }

    @Test func refreshedApplicationNamesReplacePreviousSearchAliases() async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let index = AppIndex(scanner: AppScanner(roots: []))
        let appPath = "/Applications/Chat.app"
        index.setAppsForTesting([makeEntry("微信", path: appPath)])
        let provider = AppProvider(
            index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "zh"),
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )
        let before = await provider.search(SearchContext(rawQuery: "weixin", mode: .global))
        #expect(before.map(\.title) == ["微信"])

        index.setAppsForTesting([makeEntry("飞书", path: appPath)])

        let oldName = await provider.search(SearchContext(rawQuery: "weixin", mode: .global))
        let newName = await provider.search(SearchContext(rawQuery: "feishu", mode: .global))
        #expect(oldName.isEmpty)
        #expect(newName.map(\.title) == ["飞书"])

        index.setAppsForTesting([])
        let removed = await provider.search(SearchContext(rawQuery: "feishu", mode: .global))
        #expect(removed.isEmpty)
    }

    @Test(arguments: [
        ("", ["Bravo", "Zulu"]),
        ("recent", ["Bravo", "Zulu"]),
        ("frequency", ["Zulu", "Bravo", "Alpha"]),
        ("name", ["Alpha", "Bravo", "Zulu"])
    ])
    func emptyQueryUsesApplicationSortOrder(storedOrder: String, expectedNames: [String]) async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        if !storedOrder.isEmpty {
            defaults.set(storedOrder, forKey: "dontstool.applicationSortOrder")
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = UsageStore(defaults: defaults, now: { now })
        for _ in 0..<4 {
            usage.recordUse(of: "/Applications/Zulu.app", at: now.addingTimeInterval(-100))
        }
        usage.recordUse(of: "/Applications/Bravo.app", at: now)
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([
            makeEntry("Zulu", path: "/Applications/Zulu.app"),
            makeEntry("Alpha", path: "/Applications/Alpha.app"),
            makeEntry("Bravo", path: "/Applications/Bravo.app")
        ])
        let provider = AppProvider(
            index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "en"),
            usage: usage,
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(items.map(\.title) == expectedNames)
    }

    @Test func applicationNameOrderDoesNotOverrideQueryQuality() async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("name", forKey: "dontstool.applicationSortOrder")
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([
            makeEntry("Alphabet Chrome", path: "/Applications/Alphabet Chrome.app"),
            makeEntry("Chrome", path: "/Applications/Chrome.app")
        ])
        let provider = AppProvider(
            index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "en"),
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "chrome", mode: .global))
        #expect(items.map(\.title) == ["Chrome", "Alphabet Chrome"])
    }

    @Test func fuzzyMatchesAndUsesRecencyBoost() async throws {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let usage = UsageStore(defaults: defaults, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        usage.recordUse(of: "/Applications/Chrome.app", at: Date(timeIntervalSince1970: 1_700_000_000))
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([
            makeEntry("Chrome", path: "/Applications/Chrome.app"),
            makeEntry("Chromium", path: "/Applications/Chromium.app")
        ])

        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: usage,
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )
        let items = await provider.search(SearchContext(rawQuery: "chr", mode: .global))
        #expect(items.first?.title == "Chrome")
    }

    @Test func primaryActionLaunchesAndRecordsUse() async throws {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let usage = UsageStore(defaults: defaults, now: { Date() })
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: "/Applications/Safari.app")])
        let launcher = MockAppLauncher()
        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: usage,
            launcher: launcher,
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "saf", mode: .global))
        try await items[0].primaryAction?.run()
        #expect(launcher.openedApplications.map(\.path) == ["/Applications/Safari.app"])
        #expect(usage.record(for: "/Applications/Safari.app")?.count == 1)
        let recent = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(recent.map(\.title) == ["Safari"])
    }

    @Test func failedLaunchDoesNotEnterRecentHistoryAndSearchStillFindsUnusedApps() async throws {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let usage = UsageStore(defaults: defaults)
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: "/Applications/Safari.app")])
        let launcher = MockAppLauncher()
        launcher.error = ActionError.openFailed("Safari")
        let provider = AppProvider(index: index,
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "en"),
            usage: usage, launcher: launcher, feedback: MockFeedback())
        let empty = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(empty.isEmpty)
        let results = await provider.search(SearchContext(rawQuery: "saf", mode: .global))
        #expect(results.map(\.title) == ["Safari"])
        try await results[0].primaryAction?.run()
        #expect(usage.record(for: "/Applications/Safari.app") == nil)
        let afterFailure = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(afterFailure.isEmpty)
    }

    @Test func migratedCountsRemainUsableButDoNotInventRecentLaunchTimes() async throws {
        let name = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let path = "/Applications/Safari.app"
        defaults.set(try JSONEncoder().encode([path: UsageStore.Record(count: 3, lastUsed: now)]), forKey: "dontstool.usage.records")
        let usage = UsageStore(defaults: defaults, now: { now })
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: path)])
        let provider = AppProvider(index: index, settings: settings, usage: usage,
                                   launcher: MockAppLauncher(), feedback: MockFeedback())
        let recent = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(recent.isEmpty)
        settings.setApplicationSortOrder(.frequency)
        let frequent = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(frequent.map(\.title) == ["Safari"])
        try await frequent[0].primaryAction?.run()
        settings.setApplicationSortOrder(.recent)
        let opened = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(opened.map(\.title) == ["Safari"])
        #expect(usage.record(for: path)?.count == 4)
        #expect(usage.record(for: path)?.lastUsed == now)
    }

    @Test func disabledProviderReturnsNoItems() async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setProviderEnabled("app", to: false)
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: "/Applications/Safari.app")])
        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "saf", mode: .global))
        #expect(items.isEmpty)
    }

    @Test func exposesQuitAndCopyPathActions() async throws {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: "/Applications/Safari.app")])
        let launcher = MockAppLauncher()
        let clipboard = MockClipboard()
        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: UsageStore(defaults: defaults),
            launcher: launcher,
            feedback: MockFeedback(),
            clipboard: clipboard
        )

        let items = await provider.search(SearchContext(rawQuery: "saf", mode: .global))
        #expect(items[0].actions.map(\.id) == ["app.open", "app.reveal", "app.quit", "app.copyPath"])

        try await items[0].actions.first(where: { $0.id == "app.copyPath" })?.run()
        #expect(clipboard.written == ["/Applications/Safari.app"])

        try await items[0].actions.first(where: { $0.id == "app.quit" })?.run()
        #expect(launcher.quitRequests.map(\.path) == ["/Applications/Safari.app"])
    }

    @Test func quitActionReportsWhenApplicationIsNotRunning() async throws {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: "/Applications/Safari.app")])
        let launcher = MockAppLauncher()
        launcher.quitSucceeds = false
        let feedback = MockFeedback()
        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: UsageStore(defaults: defaults),
            launcher: launcher,
            feedback: feedback
        )

        let items = await provider.search(SearchContext(rawQuery: "saf", mode: .global))
        try await items[0].actions.first(where: { $0.id == "app.quit" })?.run()
        #expect(feedback.messages == ["应用未在运行或无法退出"])
    }
}
