import Foundation

@MainActor
public final class ChromeProvider: ToolProvider {
    public static let entryCanonicalKey = "chrome:entry"

    public let id = ProviderID.chrome.rawValue
    public let displayName = "Google Chrome"
    public let priority = 200
    public let phase = SearchPhase.fast
    public private(set) var statusNotice: String?
    public var onTabsChanged: (@MainActor () -> Void)?

    private static let unifiedKeywords = ["chrome", "ch"]
    private static let tabKeywords = ["tab", "tabs", "标签页"]
    private static let bookmarkKeywords = ["bm", "书签"]

    public var keywords: [String] {
        let unavailable = Set(unavailableKeywords().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return (Self.unifiedKeywords + Self.tabKeywords + Self.bookmarkKeywords).filter { !unavailable.contains($0) }
    }

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    private let settings: SettingsStore
    private let service: any ChromeControlling
    private let prefill: (any QueryPrefilling)?
    private let clipboard: (any ClipboardProviding)?
    private let feedback: (any FeedbackProviding)?
    private let usage: UsageStore?
    private let unavailableKeywords: @MainActor () -> Set<String>
    private let tabCacheTTL: TimeInterval
    private let nowProvider: @Sendable () -> Date

    private var cachedTabs: [ChromeTab] = []
    private var tabCacheTimestamp: Date = .distantPast
    private var cachedTabNotice: String?

    public init(
        settings: SettingsStore,
        service: any ChromeControlling = SystemChromeService(),
        prefill: (any QueryPrefilling)? = nil,
        clipboard: (any ClipboardProviding)? = nil,
        feedback: (any FeedbackProviding)? = nil,
        usage: UsageStore? = nil,
        unavailableKeywords: @escaping @MainActor () -> Set<String> = { [] },
        tabCacheTTL: TimeInterval = 1.5,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.service = service
        self.prefill = prefill
        self.clipboard = clipboard
        self.feedback = feedback
        self.usage = usage
        self.unavailableKeywords = unavailableKeywords
        self.tabCacheTTL = tabCacheTTL
        self.nowProvider = nowProvider
    }

    public func homeToolEntry() -> SearchItem? {
        guard isEnabled, service.applicationPath != nil else { return nil }
        return discoveryEntry(score: 900)
    }

    public func invalidateTabCache() {
        tabCacheTimestamp = .distantPast
        cachedTabs = []
        cachedTabNotice = nil
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        statusNotice = nil
        guard isEnabled, !Task.isCancelled else { return [] }

        switch context.mode {
        case .global:
            let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return [] }
            let aliases = ["chrome", "google chrome", "tab", "tabs", "bookmark", "bookmarks", "书签", "标签页", "浏览器历史"]
            guard aliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) else {
                return []
            }
            return [discoveryEntry()]

        case .keyword(let providerID, let keyword, _) where providerID == id:
            let normalizedKeyword = keyword.lowercased()
            guard keywords.contains(normalizedKeyword) else { return [] }
            let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)

            if Self.tabKeywords.contains(normalizedKeyword) {
                return await searchTabsOnly(query: query)
            }
            if Self.bookmarkKeywords.contains(normalizedKeyword) {
                return await searchBookmarksOnly(query: query)
            }
            return await searchUnified(query: query)

        default:
            return []
        }
    }

    private func searchTabsOnly(query: String) async -> [SearchItem] {
        let (tabs, notice) = await fetchOpenTabs()
        guard !Task.isCancelled, isEnabled else { return [] }
        statusNotice = notice

        let matched = filterAndRankTabs(tabs, query: query)
        if matched.isEmpty {
            if let notice {
                return [hintItem(title: "无法读取 Chrome 标签页", subtitle: notice)]
            }
            return [hintItem(
                title: query.isEmpty ? "当前没有打开的 Chrome 标签页" : "没有匹配的 Chrome 标签页",
                subtitle: query.isEmpty ? "打开 Google Chrome 后可在此快速切换或关闭标签页" : "试试其他标题或域名关键词"
            )]
        }
        return matched.prefix(30).map { makeTabItem($0.tab, score: $0.score) }
    }

    private func searchBookmarksOnly(query: String) async -> [SearchItem] {
        let bookmarks = await service.loadBookmarks()
        guard !Task.isCancelled, isEnabled else { return [] }

        let matched = filterAndRankBookmarks(bookmarks, query: query)
        guard !matched.isEmpty else {
            return [hintItem(
                title: query.isEmpty ? "未找到 Chrome 书签" : "没有匹配的 Chrome 书签",
                subtitle: query.isEmpty ? "请确认已安装并使用过 Google Chrome" : "可按书签标题、目录名或网址筛选"
            )]
        }
        return matched.prefix(30).map { makeBookmarkItem($0.bookmark, score: $0.score) }
    }

    private func searchUnified(query: String) async -> [SearchItem] {
        async let tabsTask = fetchOpenTabs()
        async let bookmarksTask = service.loadBookmarks()
        async let historyTask = service.loadHistory(limit: 400)

        let (tabs, tabNotice) = await tabsTask
        let bookmarks = await bookmarksTask
        let history = await historyTask
        guard !Task.isCancelled, isEnabled else { return [] }
        statusNotice = tabNotice

        var items: [SearchItem] = []
        var seenURLs = Set<String>()

        let rankedTabs = filterAndRankTabs(tabs, query: query)
        for entry in rankedTabs.prefix(15) {
            seenURLs.insert(normalizedURLKey(entry.tab.url))
            items.append(makeTabItem(entry.tab, score: entry.score))
        }

        let rankedBookmarks = filterAndRankBookmarks(bookmarks, query: query)
        for entry in rankedBookmarks.prefix(15) {
            let key = normalizedURLKey(entry.bookmark.url)
            guard seenURLs.insert(key).inserted else { continue }
            items.append(makeBookmarkItem(entry.bookmark, score: entry.score))
        }

        let rankedHistory = filterAndRankHistory(history, query: query)
        for entry in rankedHistory.prefix(15) {
            let key = normalizedURLKey(entry.entry.url)
            guard seenURLs.insert(key).inserted else { continue }
            items.append(makeHistoryItem(entry.entry, score: entry.score))
        }

        items.append(contentsOf: quickCommandItems(matching: query))

        if items.isEmpty {
            return [hintItem(
                title: "没有匹配的 Chrome 内容",
                subtitle: "支持搜索已打开标签页、书签与历史记录，或输入 new / 无痕 新建窗口"
            )]
        }

        return Array(items.sorted { $0.score > $1.score }.prefix(30))
    }

    private func fetchOpenTabs() async -> ([ChromeTab], String?) {
        let now = nowProvider()
        if now.timeIntervalSince(tabCacheTimestamp) < tabCacheTTL {
            return (cachedTabs, cachedTabNotice)
        }
        do {
            let tabs = try await service.listOpenTabs()
            guard !Task.isCancelled else { return ([], nil) }
            cachedTabs = tabs
            cachedTabNotice = nil
            tabCacheTimestamp = nowProvider()
            return (tabs, nil)
        } catch {
            guard !Task.isCancelled else { return ([], nil) }
            cachedTabs = []
            cachedTabNotice = error.localizedDescription
            tabCacheTimestamp = nowProvider()
            return ([], error.localizedDescription)
        }
    }

    // MARK: - Ranking

    private func filterAndRankTabs(_ tabs: [ChromeTab], query: String) -> [(tab: ChromeTab, score: Double)] {
        if query.isEmpty {
            return tabs.enumerated().map { offset, tab in
                let activeBonus = tab.isActive ? 50.0 : 0.0
                return (tab, 3200 + activeBonus - Double(offset))
            }
        }
        let lower = query.lowercased()
        return tabs.compactMap { tab in
            if let titleScore = FuzzyMatcher.score(query: query, candidate: tab.title) {
                return (tab, 3200 + min(titleScore, 600))
            }
            if tab.url.lowercased().contains(lower) {
                return (tab, 3050)
            }
            return nil
        }.sorted { $0.score > $1.score }
    }

    private func filterAndRankBookmarks(_ bookmarks: [ChromeBookmark], query: String) -> [(bookmark: ChromeBookmark, score: Double)] {
        if query.isEmpty {
            return bookmarks.enumerated().map { offset, bookmark in
                (bookmark, 2200 - Double(offset) * 0.1)
            }
        }
        let lower = query.lowercased()
        return bookmarks.compactMap { bookmark in
            if let titleScore = FuzzyMatcher.score(query: query, candidate: bookmark.title) {
                return (bookmark, 2200 + min(titleScore, 600))
            }
            if bookmark.url.lowercased().contains(lower) {
                return (bookmark, 2050)
            }
            if !bookmark.folderPath.isEmpty, FuzzyMatcher.score(query: query, candidate: bookmark.folderPath) != nil {
                return (bookmark, 1950)
            }
            return nil
        }.sorted { $0.score > $1.score }
    }

    private func filterAndRankHistory(_ entries: [ChromeHistoryEntry], query: String) -> [(entry: ChromeHistoryEntry, score: Double)] {
        if query.isEmpty {
            return entries.enumerated().map { offset, entry in
                (entry, 1400 - Double(offset) * 0.1)
            }
        }
        let lower = query.lowercased()
        return entries.compactMap { entry in
            let visitBonus = min(Double(entry.visitCount) * 2.0, 100.0)
            if let titleScore = FuzzyMatcher.score(query: query, candidate: entry.title) {
                return (entry, 1400 + min(titleScore, 500) + visitBonus)
            }
            if entry.url.lowercased().contains(lower) {
                return (entry, 1250 + visitBonus)
            }
            return nil
        }.sorted { $0.score > $1.score }
    }

    // MARK: - Item Construction

    private var chromeIcon: ItemIcon {
        if let appPath = service.applicationPath {
            return .application(path: appPath)
        }
        return .symbol(name: "globe", tint: .blue)
    }

    private func makeTabItem(_ tab: ChromeTab, score: Double) -> SearchItem {
        let settings = self.settings
        let service = self.service
        let clipboard = self.clipboard
        let feedback = self.feedback
        let usage = self.usage
        let providerID = id

        var actions: [ItemAction] = [
            ItemAction(id: "chrome.tab.switch", title: "切换到标签页", presentation: .openWindow, symbol: "arrow.uturn.forward") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    try await service.switchToTab(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            },
            ItemAction(id: "chrome.tab.close", title: "关闭标签页", presentation: .keepPanelOpen, symbol: "xmark.circle") { [weak self] in
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    try await service.closeTab(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                    self?.invalidateTabCache()
                    feedback?.show("已关闭标签页：\(tab.title)")
                    self?.onTabsChanged?()
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            }
        ]
        actions.append(contentsOf: copyActions(title: tab.title, url: tab.url, clipboard: clipboard, feedback: feedback))

        return SearchItem(
            providerID: id,
            group: .tool,
            title: tab.title,
            subtitle: tab.url,
            icon: chromeIcon,
            score: score,
            canonicalKey: "chrome:tab:\(tab.windowIndex):\(tab.tabIndex):\(normalizedURLKey(tab.url))",
            actions: actions,
            badge: SearchItemBadge(text: tab.isActive ? "当前标签" : "标签页", tint: .blue)
        )
    }

    private func makeBookmarkItem(_ bookmark: ChromeBookmark, score: Double) -> SearchItem {
        let subtitle = bookmark.folderPath.isEmpty ? bookmark.url : "\(bookmark.folderPath) · \(bookmark.url)"
        return SearchItem(
            providerID: id,
            group: .tool,
            title: bookmark.title,
            subtitle: subtitle,
            icon: chromeIcon,
            score: score,
            canonicalKey: "chrome:bookmark:\(bookmark.id)",
            actions: urlActions(title: bookmark.title, urlString: bookmark.url),
            badge: SearchItemBadge(text: "书签", tint: .amber)
        )
    }

    private func makeHistoryItem(_ entry: ChromeHistoryEntry, score: Double) -> SearchItem {
        return SearchItem(
            providerID: id,
            group: .tool,
            title: entry.title,
            subtitle: entry.url,
            icon: chromeIcon,
            score: score,
            canonicalKey: "chrome:history:\(normalizedURLKey(entry.url))",
            actions: urlActions(title: entry.title, urlString: entry.url),
            badge: SearchItemBadge(text: "历史", tint: .gray)
        )
    }

    private func quickCommandItems(matching query: String) -> [SearchItem] {
        let settings = self.settings
        let service = self.service
        let feedback = self.feedback
        let usage = self.usage
        let providerID = id

        var result: [SearchItem] = []
        let newTabAliases = ["new", "new tab", "tab", "新建", "新标签页"]
        if query.isEmpty || newTabAliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) {
            result.append(SearchItem(
                providerID: id,
                group: .tool,
                title: "新建 Chrome 标签页",
                subtitle: "在 Google Chrome 中打开一个新的空白标签页",
                icon: chromeIcon,
                score: query.isEmpty ? 800 : 2500,
                canonicalKey: "chrome:action:new-tab",
                actions: [ItemAction(id: "chrome.newTab", title: "新建标签页", presentation: .openWindow, symbol: "plus.square") { [weak self] in
                    guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                    do {
                        try await service.openNewTab(incognito: false)
                        usage?.recordUse(of: Self.entryCanonicalKey)
                        self?.invalidateTabCache()
                    } catch {
                        feedback?.show(error.localizedDescription)
                    }
                }]
            ))
        }

        let incognitoAliases = ["incognito", "private", "new incognito", "无痕", "隐私窗口"]
        if query.isEmpty || incognitoAliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) {
            result.append(SearchItem(
                providerID: id,
                group: .tool,
                title: "新建 Chrome 无痕窗口",
                subtitle: "在 Google Chrome 中打开无痕浏览窗口",
                icon: chromeIcon,
                score: query.isEmpty ? 790 : 2550,
                canonicalKey: "chrome:action:incognito",
                actions: [ItemAction(id: "chrome.newIncognito", title: "新建无痕窗口", presentation: .openWindow, symbol: "eye.slash") {
                    guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                    do {
                        try await service.openNewTab(incognito: true)
                        usage?.recordUse(of: Self.entryCanonicalKey)
                    } catch {
                        feedback?.show(error.localizedDescription)
                    }
                }]
            ))
        }
        return result
    }

    private func urlActions(title: String, urlString: String) -> [ItemAction] {
        let settings = self.settings
        let service = self.service
        let clipboard = self.clipboard
        let feedback = self.feedback
        let usage = self.usage
        let providerID = id

        var actions: [ItemAction] = [
            ItemAction(id: "chrome.open", title: "在 Chrome 中打开", presentation: .openWindow, symbol: "safari") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                guard let url = URL(string: urlString) else {
                    feedback?.show(ChromeControlError.invalidURL.localizedDescription)
                    return
                }
                do {
                    try await service.openURL(url, incognito: false)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            }
        ]
        if let clipboard {
            actions.append(ItemAction(id: "chrome.copyURL", title: "复制网址", presentation: .dismissThenRun, symbol: "link") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                clipboard.writeString(urlString)
                usage?.recordUse(of: Self.entryCanonicalKey)
                feedback?.show("已复制网址")
            })
        }
        actions.append(ItemAction(id: "chrome.openIncognito", title: "在无痕窗口打开", presentation: .openWindow, symbol: "eye.slash") {
            guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
            guard let url = URL(string: urlString) else {
                feedback?.show(ChromeControlError.invalidURL.localizedDescription)
                return
            }
            do {
                try await service.openURL(url, incognito: true)
                usage?.recordUse(of: Self.entryCanonicalKey)
            } catch {
                feedback?.show(error.localizedDescription)
            }
        })
        if let clipboard {
            actions.append(ItemAction(id: "chrome.copyMarkdown", title: "复制 Markdown 链接", presentation: .dismissThenRun, symbol: "number") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                clipboard.writeString("[\(title)](\(urlString))")
                usage?.recordUse(of: Self.entryCanonicalKey)
                feedback?.show("已复制 Markdown 链接")
            })
        }
        return actions
    }

    private func copyActions(
        title: String,
        url: String,
        clipboard: (any ClipboardProviding)?,
        feedback: (any FeedbackProviding)?
    ) -> [ItemAction] {
        guard let clipboard else { return [] }
        let settings = self.settings
        let usage = self.usage
        let providerID = id
        return [
            ItemAction(id: "chrome.copyURL", title: "复制网址", presentation: .dismissThenRun, symbol: "link") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                clipboard.writeString(url)
                usage?.recordUse(of: Self.entryCanonicalKey)
                feedback?.show("已复制网址")
            },
            ItemAction(id: "chrome.copyMarkdown", title: "复制 Markdown 链接", presentation: .dismissThenRun, symbol: "number") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                clipboard.writeString("[\(title)](\(url))")
                usage?.recordUse(of: Self.entryCanonicalKey)
                feedback?.show("已复制 Markdown 链接")
            }
        ]
    }

    private func discoveryEntry(score: Double = 1800) -> SearchItem {
        let keyword = keywords.first ?? "chrome"
        let prefill = self.prefill
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "Google Chrome",
            subtitle: "输入 \(keyword) 搜索标签页、书签和历史（tab 只搜标签页，bm 只搜书签）",
            icon: chromeIcon,
            score: score,
            canonicalKey: Self.entryCanonicalKey,
            actions: [ItemAction(id: "chrome.enter", title: "进入 Chrome 搜索", presentation: .keepPanelOpen, symbol: "globe") {
                prefill?.prefill(keyword + " ")
            }],
            keyword: keyword
        )
    }

    private func hintItem(title: String, subtitle: String) -> SearchItem {
        let feedback = self.feedback
        return SearchItem(
            providerID: id,
            group: .tool,
            title: title,
            subtitle: subtitle,
            icon: chromeIcon,
            score: 1000,
            canonicalKey: "chrome:hint",
            actions: [ItemAction(id: "chrome.hint", title: "提示", presentation: .keepPanelOpen, symbol: "info.circle") {
                feedback?.show(subtitle)
            }]
        )
    }

    private func normalizedURLKey(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            .lowercased()
    }
}
