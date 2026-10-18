import Foundation

@MainActor
public final class FileProvider: ToolProvider {
    public let id = ProviderID.file.rawValue
    public let displayName = "文件"
    public let keywords: [String] = []
    public let priority = 50
    public let phase = SearchPhase.slow
    public private(set) var statusNotice: String?

    private let settings: SettingsStore
    private let usage: UsageStore
    private let launcher: AppLaunching
    private let feedback: FeedbackProviding
    private let service: FileSearchService

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) && settings.fileSearchEnabled }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        settings: SettingsStore,
        usage: UsageStore,
        launcher: AppLaunching,
        feedback: FeedbackProviding,
        service: FileSearchService = FileSearchService()
    ) {
        self.settings = settings
        self.usage = usage
        self.launcher = launcher
        self.feedback = feedback
        self.service = service
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        let interval = Performance.begin("file.search")
        defer { Performance.end(interval) }
        statusNotice = nil
        guard case .global = context.mode, isEnabled, !context.query.isEmpty else { return [] }

        do {
            let result = try await service.search(query: context.query, timeout: .milliseconds(300))
            if result.timedOut {
                statusNotice = result.hits.isEmpty ? "文件搜索超时" : "文件搜索较慢，已显示部分结果"
            }
            return result.hits.map(makeItem)
        } catch {
            statusNotice = "文件搜索不可用"
            Log.provider.error("文件搜索失败: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func makeItem(hit: FileSearchHit) -> SearchItem {
        let launcher = self.launcher
        let usage = self.usage
        let feedback = self.feedback
        let key = hit.url.path
        let score = hit.score + usage.boost(for: key)

        return SearchItem(
            providerID: id,
            group: .file,
            title: hit.url.lastPathComponent,
            subtitle: PathDisplay.parentDirectory(of: hit.url),
            icon: .file(path: hit.url.path),
            score: score,
            canonicalKey: key,
            actions: [
                ItemAction(id: "file.open", title: "打开") {
                    do {
                        try launcher.openFile(at: hit.url)
                        usage.recordUse(of: key)
                    } catch {
                        feedback.show(error.localizedDescription)
                    }
                },
                ItemAction(id: "file.reveal", title: "在 Finder 中显示") {
                    launcher.revealInFinder(hit.url)
                }
            ]
        )
    }
}
