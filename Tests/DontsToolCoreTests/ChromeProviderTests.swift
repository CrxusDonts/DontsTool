import Foundation
import os
import SQLite3
import Testing
@testable import DontsToolCore

@Suite("ChromeDataReader & ChromeProvider")
@MainActor
struct ChromeProviderTests {
    private final class MockChromeService: ChromeControlling, @unchecked Sendable {
        struct State {
            var applicationPath: String? = "/Applications/Google Chrome.app"
            var bookmarks: [ChromeBookmark] = []
            var history: [ChromeHistoryEntry] = []
            var tabs: [ChromeTab] = []
            var tabsError: Error?
            var listTabsCalls = 0
            var switchedTabs: [(Int, Int)] = []
            var closedTabs: [(Int, Int)] = []
            var openedURLs: [(URL, Bool)] = []
            var openedNewTabs: [Bool] = []
        }

        let state = OSAllocatedUnfairLock(initialState: State())

        var applicationPath: String? { state.withLock(\.applicationPath) }

        func loadBookmarks() async -> [ChromeBookmark] {
            state.withLock(\.bookmarks)
        }

        func loadHistory(limit: Int) async -> [ChromeHistoryEntry] {
            Array(state.withLock(\.history).prefix(limit))
        }

        func listOpenTabs() async throws -> [ChromeTab] {
            try state.withLock {
                $0.listTabsCalls += 1
                if let error = $0.tabsError { throw error }
                return $0.tabs
            }
        }

        func switchToTab(windowIndex: Int, tabIndex: Int) async throws {
            state.withLock { $0.switchedTabs.append((windowIndex, tabIndex)) }
        }

        func closeTab(windowIndex: Int, tabIndex: Int) async throws {
            state.withLock {
                $0.closedTabs.append((windowIndex, tabIndex))
                $0.tabs.removeAll { $0.windowIndex == windowIndex && $0.tabIndex == tabIndex }
            }
        }

        func openURL(_ url: URL, incognito: Bool) async throws {
            state.withLock { $0.openedURLs.append((url, incognito)) }
        }

        func openNewTab(incognito: Bool) async throws {
            state.withLock { $0.openedNewTabs.append(incognito) }
        }
    }

    private final class SpyClipboard: ClipboardProviding, @unchecked Sendable {
        var written: [String] = []
        func writeString(_ text: String) { written.append(text) }
        func readString() -> String? { written.last }
    }

    private final class SpyFeedback: FeedbackProviding {
        var messages: [String] = []
        func show(_ message: String) { messages.append(message) }
    }

    private final class SpyPrefill: QueryPrefilling {
        var values: [String] = []
        func prefill(_ query: String) { values.append(query) }
    }

    private func makeSettings() -> (SettingsStore, UserDefaults, String) {
        let suite = "dontstool.tests.chrome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults, systemLanguageCode: "zh"), defaults, suite)
    }

    // MARK: - Data Reader Tests

    @Test func discoversProfilesReadsDisplayNamesAndSkipsSystemProfiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("chrome-profiles-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let localState: [String: Any] = [
            "profile": [
                "info_cache": [
                    "Default": ["name": "个人"],
                    "Profile 1": ["name": "工作"],
                    "Guest Profile": ["name": "Guest"]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: localState).write(to: root.appendingPathComponent("Local State"))

        for dir in ["Default", "Profile 1", "Guest Profile", "System Profile", "EmptyDir"] {
            let folder = root.appendingPathComponent(dir, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if dir != "EmptyDir" {
                try Data("{}".utf8).write(to: folder.appendingPathComponent("Bookmarks"))
            }
        }

        let profiles = ChromeDataReader.discoverProfiles(in: root)
        #expect(profiles.map(\.directoryName) == ["Default", "Profile 1"])
        #expect(profiles.map(\.displayName) == ["个人", "工作"])
    }

    @Test func parsesNestedBookmarksAndRejectsNonWebSchemes() throws {
        let json: [String: Any] = [
            "roots": [
                "bookmark_bar": [
                    "name": "书签栏",
                    "type": "folder",
                    "children": [
                        ["id": "1", "name": "GitHub", "type": "url", "url": "https://github.com"],
                        ["id": "2", "name": "Bookmarklet", "type": "url", "url": "javascript:alert(1)"],
                        ["id": "3", "name": "LocalFile", "type": "url", "url": "file:///etc/passwd"],
                        [
                            "name": "开发文档",
                            "type": "folder",
                            "children": [
                                ["id": "4", "name": "Swift Docs", "type": "url", "url": "https://swift.org/documentation/"]
                            ]
                        ]
                    ]
                ],
                "other": [
                    "name": "其他书签",
                    "type": "folder",
                    "children": [
                        ["id": "5", "name": "", "type": "url", "url": "https://example.com/news"]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let bookmarks = ChromeDataReader.parseBookmarksJSON(data, profileName: "个人")

        #expect(bookmarks.count == 3)
        #expect(bookmarks[0].title == "GitHub")
        #expect(bookmarks[0].folderPath == "书签栏")
        #expect(bookmarks[1].title == "Swift Docs")
        #expect(bookmarks[1].folderPath == "书签栏 / 开发文档")
        #expect(bookmarks[2].title == "https://example.com/news")
        #expect(bookmarks[2].folderPath == "其他书签")
    }

    @Test func readsSQLiteHistoryDecodesWebKitTimestampsAndFiltersHidden() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("chrome-history-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("History")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        // 2026-01-01T00:00:00Z = 1767225600 Unix seconds -> WebKit micros
        let unix2026: Int64 = 1_767_225_600
        let webkit2026: Int64 = (unix2026 + 11_644_473_600) * 1_000_000
        let webkit2025: Int64 = (unix2026 - 86_400 + 11_644_473_600) * 1_000_000

        let sql = """
        CREATE TABLE urls (
            id INTEGER PRIMARY KEY,
            url LONGVARCHAR,
            title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0,
            typed_count INTEGER DEFAULT 0,
            last_visit_time INTEGER NOT NULL,
            hidden INTEGER DEFAULT 0
        );
        INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES
            ('https://developer.apple.com', 'Apple Developer', 12, \(webkit2026), 0),
            ('https://swift.org', 'Swift.org', 5, \(webkit2025), 0),
            ('https://hidden.example.com', 'Hidden', 99, \(webkit2026), 1),
            ('chrome://settings', 'Settings', 20, \(webkit2026), 0);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

        let entries = ChromeDataReader.readHistorySQLite(at: dbURL, profileName: "Default", limit: 20)
        #expect(entries.count == 2)
        #expect(entries[0].url == "https://developer.apple.com")
        #expect(entries[0].title == "Apple Developer")
        #expect(entries[0].visitCount == 12)
        #expect(abs(entries[0].lastVisitedAt.timeIntervalSince1970 - Double(unix2026)) < 1.0)
        #expect(entries[1].url == "https://swift.org")
    }

    @Test func parsesOpenTabsOutputWithSpecialCharactersInTitle() {
        let us = String(UnicodeScalar(31))
        let rs = String(UnicodeScalar(30))
        let raw = [
            ["1", "2", "1", "PR #42 | Fix, \"quotes\" & tabs", "https://github.com/org/repo/pull/42"].joined(separator: us),
            ["2", "1", "0", "", "https://docs.swift.org"].joined(separator: us)
        ].joined(separator: rs)

        let tabs = SystemChromeService.parseOpenTabsOutput(raw)
        #expect(tabs.count == 2)
        #expect(tabs[0] == ChromeTab(
            windowIndex: 1,
            tabIndex: 2,
            title: "PR #42 | Fix, \"quotes\" & tabs",
            url: "https://github.com/org/repo/pull/42",
            isActive: true
        ))
        #expect(tabs[1].title == "https://docs.swift.org")
        #expect(!tabs[1].isActive)
    }

    // MARK: - Provider Tests

    @Test func globalEmptyQueryStaysSilentAndNonEmptyQueryShowsDiscoveryEntry() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = MockChromeService()
        let prefill = SpyPrefill()
        let provider = ChromeProvider(settings: settings, service: service, prefill: prefill)

        let emptyResults = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(emptyResults.isEmpty)

        let discovery = await provider.search(SearchContext(rawQuery: "书签", mode: .global))
        #expect(discovery.count == 1)
        #expect(discovery[0].title == "Google Chrome")
        try await discovery[0].primaryAction?.run()
        #expect(prefill.values == ["chrome "])
    }

    @Test func unifiedSearchPrioritizesTabsOverBookmarksOverHistoryAndDeduplicatesURLs() async {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = MockChromeService()
        service.state.withLock {
            $0.tabs = [
                ChromeTab(windowIndex: 1, tabIndex: 1, title: "GitHub Dashboard", url: "https://github.com/", isActive: true)
            ]
            $0.bookmarks = [
                ChromeBookmark(id: "b1", title: "GitHub Bookmark", url: "https://github.com", folderPath: "书签栏"),
                ChromeBookmark(id: "b2", title: "GitHub Gist", url: "https://gist.github.com", folderPath: "开发")
            ]
            $0.history = [
                ChromeHistoryEntry(title: "GitHub Gist History", url: "https://gist.github.com/", visitCount: 8),
                ChromeHistoryEntry(title: "GitHub Status", url: "https://www.githubstatus.com", visitCount: 3)
            ]
        }

        let provider = ChromeProvider(settings: settings, service: service)
        let results = await provider.search(SearchContext(
            rawQuery: "chrome github",
            mode: .keyword(providerID: provider.id, keyword: "chrome", argument: "github")
        ))

        let titles = results.map(\.title)
        #expect(titles == ["GitHub Dashboard", "GitHub Gist", "GitHub Status"])
        #expect(results[0].badge?.text == "当前标签")
        #expect(results[1].badge?.text == "书签")
        #expect(results[2].badge?.text == "历史")
    }

    @Test func tabAndBookmarkFocusedKeywordsFilterToTheirOwnSources() async {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = MockChromeService()
        service.state.withLock {
            $0.tabs = [ChromeTab(windowIndex: 1, tabIndex: 1, title: "Open Tab", url: "https://tab.example.com")]
            $0.bookmarks = [ChromeBookmark(id: "b1", title: "Saved Bookmark", url: "https://bm.example.com", folderPath: "书签栏")]
        }

        let provider = ChromeProvider(settings: settings, service: service)

        let tabItems = await provider.search(SearchContext(
            rawQuery: "tab ",
            mode: .keyword(providerID: provider.id, keyword: "tab", argument: "")
        ))
        #expect(tabItems.map(\.title) == ["Open Tab"])

        let bmItems = await provider.search(SearchContext(
            rawQuery: "bm ",
            mode: .keyword(providerID: provider.id, keyword: "bm", argument: "")
        ))
        #expect(bmItems.map(\.title) == ["Saved Bookmark"])
    }

    @Test func automationDeniedSetsStatusNoticeWhileStillReturningBookmarksAndHistory() async {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = MockChromeService()
        service.state.withLock {
            $0.tabsError = ChromeControlError.automationDenied
            $0.bookmarks = [ChromeBookmark(id: "b1", title: "Cloudflare Docs", url: "https://developers.cloudflare.com")]
        }

        let provider = ChromeProvider(settings: settings, service: service)
        let results = await provider.search(SearchContext(
            rawQuery: "chrome cloudflare",
            mode: .keyword(providerID: provider.id, keyword: "chrome", argument: "cloudflare")
        ))

        #expect(provider.statusNotice?.contains("自动化") == true)
        #expect(results.map(\.title) == ["Cloudflare Docs"])
    }

    @Test func tabAndURLActionsInvokeServiceClipboardFeedbackAndRefresh() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = MockChromeService()
        service.state.withLock {
            $0.tabs = [ChromeTab(windowIndex: 2, tabIndex: 3, title: "Swift Evolution", url: "https://swift.org/evolution")]
            $0.bookmarks = [ChromeBookmark(id: "b1", title: "Apple", url: "https://apple.com")]
        }

        let clipboard = SpyClipboard()
        let feedback = SpyFeedback()
        let usage = UsageStore(defaults: defaults)
        let provider = ChromeProvider(
            settings: settings,
            service: service,
            clipboard: clipboard,
            feedback: feedback,
            usage: usage,
            tabCacheTTL: 60
        )
        #expect(provider.homeToolEntry()?.canonicalKey == ChromeProvider.entryCanonicalKey)
        var refreshCount = 0
        provider.onTabsChanged = { refreshCount += 1 }

        let items = await provider.search(SearchContext(
            rawQuery: "chrome ",
            mode: .keyword(providerID: provider.id, keyword: "chrome", argument: "")
        ))
        let tabItem = try #require(items.first { $0.title == "Swift Evolution" })
        let bookmarkItem = try #require(items.first { $0.title == "Apple" })
        let newTabItem = try #require(items.first { $0.title == "新建 Chrome 标签页" })
        let incognitoItem = try #require(items.first { $0.title == "新建 Chrome 无痕窗口" })

        try await tabItem.actions.first { $0.id == "chrome.tab.switch" }?.run()
        try await tabItem.actions.first { $0.id == "chrome.copyURL" }?.run()
        try await tabItem.actions.first { $0.id == "chrome.copyMarkdown" }?.run()
        try await tabItem.actions.first { $0.id == "chrome.tab.close" }?.run()

        try await bookmarkItem.actions.first { $0.id == "chrome.open" }?.run()
        try await bookmarkItem.actions.first { $0.id == "chrome.openIncognito" }?.run()

        try await newTabItem.primaryAction?.run()
        try await incognitoItem.primaryAction?.run()

        let snapshot = service.state.withLock { $0 }
        #expect(snapshot.switchedTabs.count == 1)
        #expect(snapshot.switchedTabs[0] == (2, 3))
        #expect(snapshot.closedTabs.count == 1)
        #expect(snapshot.closedTabs[0] == (2, 3))
        #expect(refreshCount == 1)
        #expect(clipboard.written == [
            "https://swift.org/evolution",
            "[Swift Evolution](https://swift.org/evolution)"
        ])
        #expect(snapshot.openedURLs.count == 2)
        #expect(snapshot.openedURLs[0].0.absoluteString == "https://apple.com")
        #expect(snapshot.openedURLs[0].1 == false)
        #expect(snapshot.openedURLs[1].1 == true)
        #expect(snapshot.openedNewTabs == [false, true])
        #expect(usage.record(for: ChromeProvider.entryCanonicalKey)?.count == 8)

        // Closing a tab invalidates the tab cache, so a subsequent query re-fetches from the service.
        _ = await provider.search(SearchContext(
            rawQuery: "tab ",
            mode: .keyword(providerID: provider.id, keyword: "tab", argument: "")
        ))
        #expect(service.state.withLock(\.listTabsCalls) == 2)
    }

    @Test func unavailableKeywordsAreYieldedToUserShortcuts() {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let provider = ChromeProvider(
            settings: settings,
            service: MockChromeService(),
            unavailableKeywords: { ["ch", "bm"] }
        )
        #expect(!provider.keywords.contains("ch"))
        #expect(!provider.keywords.contains("bm"))
        #expect(provider.keywords.contains("chrome"))
        #expect(provider.keywords.contains("tab"))
    }
}
