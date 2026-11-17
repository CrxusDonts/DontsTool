import Foundation

@MainActor
public final class AppProvider: ToolProvider {
    public let id = ProviderID.app.rawValue
    public let displayName = "应用"
    public let keywords: [String] = []
    public let priority = 100
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }

    private let index: AppIndex
    private let settings: SettingsStore
    private let usage: UsageStore
    private let launcher: AppLaunching
    private let feedback: FeedbackProviding
    private let clipboard: ClipboardProviding
    private var indexedApps: [AppEntry] = []
    private var searchDocuments: [String: AppSearchDocument] = [:]

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        index: AppIndex,
        settings: SettingsStore,
        usage: UsageStore,
        launcher: AppLaunching,
        feedback: FeedbackProviding,
        clipboard: ClipboardProviding = SystemClipboard()
    ) {
        self.index = index
        self.settings = settings
        self.usage = usage
        self.launcher = launcher
        self.feedback = feedback
        self.clipboard = clipboard
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard case .global = context.mode, isEnabled else { return [] }
        if context.query.isEmpty {
            return commonApps().enumerated().map { offset, entry in
                makeItem(entry, score: 1000 - Double(offset))
            }
        }

        refreshSearchDocuments()
        let query = FuzzyMatcher.normalize(context.query.trimmingCharacters(in: .whitespacesAndNewlines))
        let compactQuery = query.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let scored = index.apps.compactMap { entry -> (AppEntry, Double)? in
            guard let match = searchDocuments[entry.id]?.score(normalizedQuery: query, compactQuery: compactQuery) else {
                return nil
            }
            return (entry, match + usage.boost(for: entry.id))
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.displayName.localizedStandardCompare($1.0.displayName) == .orderedAscending
        }
        .prefix(8)

        return scored.map { makeItem($0.0, score: $0.1) }
    }

    private func refreshSearchDocuments() {
        guard indexedApps != index.apps else { return }
        var updated: [String: AppSearchDocument] = [:]
        updated.reserveCapacity(index.apps.count)
        for entry in index.apps {
            if let existing = searchDocuments[entry.id],
               existing.displayName == entry.displayName, existing.url == entry.url {
                updated[entry.id] = existing
            } else {
                updated[entry.id] = AppSearchDocument(entry: entry)
            }
        }
        searchDocuments = updated
        indexedApps = index.apps
    }

    private func commonApps() -> [AppEntry] {
        let candidates = settings.applicationSortOrder == .recent
            ? index.apps.filter {
                guard let record = usage.record(for: $0.id) else { return false }
                return record.count > 0 && record.lastUsed > .distantPast
            }
            : index.apps
        return Array(candidates.sorted { lhs, rhs in
            let left = usage.record(for: lhs.id)
            let right = usage.record(for: rhs.id)
            switch settings.applicationSortOrder {
            case .recent:
                let leftDate = left?.lastUsed ?? .distantPast
                let rightDate = right?.lastUsed ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
            case .frequency:
                let leftCount = left?.count ?? 0
                let rightCount = right?.count ?? 0
                if leftCount != rightCount { return leftCount > rightCount }
                let leftDate = left?.lastUsed ?? .distantPast
                let rightDate = right?.lastUsed ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
            case .name:
                break
            }
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id < rhs.id
        }.prefix(4))
    }

    private func makeItem(_ entry: AppEntry, score: Double) -> SearchItem {
        let launcher = self.launcher
        let usage = self.usage
        let feedback = self.feedback
        let clipboard = self.clipboard
        let key = entry.id

        return SearchItem(
            providerID: id,
            group: .app,
            title: entry.displayName,
            subtitle: PathDisplay.parentDirectory(of: entry.url),
            icon: .application(path: entry.url.path),
            score: score,
            canonicalKey: key,
            actions: [
                ItemAction(id: "app.open", title: "打开", symbol: "arrow.up.forward.app") {
                    do {
                        try await launcher.openApplication(at: entry.url)
                        usage.recordUse(of: key)
                    } catch {
                        feedback.show("无法打开应用")
                        Log.provider.error("打开应用失败: \(entry.url.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
                    }
                },
                ItemAction(id: "app.reveal", title: "在访达中显示", symbol: "folder") {
                    launcher.revealInFinder(entry.url)
                },
                ItemAction(id: "app.quit", title: "退出应用", symbol: "power") {
                    guard launcher.quitApplication(at: entry.url) else {
                        feedback.show("应用未在运行或无法退出")
                        return
                    }
                },
                ItemAction(id: "app.copyPath", title: "复制路径", symbol: "doc.on.doc") {
                    clipboard.writeString(entry.url.path)
                    feedback.show("已复制路径")
                }
            ]
        )
    }
}
