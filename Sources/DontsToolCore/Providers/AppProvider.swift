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

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        index: AppIndex,
        settings: SettingsStore,
        usage: UsageStore,
        launcher: AppLaunching,
        feedback: FeedbackProviding
    ) {
        self.index = index
        self.settings = settings
        self.usage = usage
        self.launcher = launcher
        self.feedback = feedback
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard case .global = context.mode, isEnabled else { return [] }
        if context.query.isEmpty {
            return commonApps().enumerated().map { offset, entry in
                makeItem(entry, score: 1000 - Double(offset))
            }
        }

        let scored = index.apps.compactMap { entry -> (AppEntry, Double)? in
            guard let match = FuzzyMatcher.score(query: context.query, candidate: entry.displayName) else {
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

    private func commonApps() -> [AppEntry] {
        var seen: Set<String> = []
        var result: [AppEntry] = []
        let byID = Dictionary(uniqueKeysWithValues: index.apps.map { ($0.id, $0) })

        for key in usage.topKeys(limit: 32) {
            guard let entry = byID[key], seen.insert(entry.id).inserted else { continue }
            result.append(entry)
            if result.count == 4 { return result }
        }

        for entry in index.apps where seen.insert(entry.id).inserted {
            result.append(entry)
            if result.count == 4 { break }
        }
        return result
    }

    private func makeItem(_ entry: AppEntry, score: Double) -> SearchItem {
        let launcher = self.launcher
        let usage = self.usage
        let feedback = self.feedback
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
                ItemAction(id: "app.open", title: "打开") {
                    do {
                        try await launcher.openApplication(at: entry.url)
                        usage.recordUse(of: key)
                    } catch {
                        feedback.show("无法打开应用")
                        Log.provider.error("打开应用失败: \(entry.url.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
                    }
                },
                ItemAction(id: "app.reveal", title: "在 Finder 中显示") {
                    launcher.revealInFinder(entry.url)
                }
            ]
        )
    }
}
