import Foundation

@MainActor
public final class FileProvider: ToolProvider {
    public let id = ProviderID.file.rawValue
    public let displayName = "文件"
    public let keywords = ["file"]
    public let priority = 50
    public let phase = SearchPhase.slow
    public let supportsGlobalSearch = false
    public private(set) var statusNotice: String?

    private let settings: SettingsStore
    private let usage: UsageStore
    private let launcher: AppLaunching
    private let feedback: FeedbackProviding
    private let service: FileSearchService
    private let clipboard: ClipboardProviding

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) && settings.fileSearchEnabled }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        settings: SettingsStore,
        usage: UsageStore,
        launcher: AppLaunching,
        feedback: FeedbackProviding,
        service: FileSearchService = FileSearchService(),
        clipboard: ClipboardProviding = SystemClipboard()
    ) {
        self.settings = settings
        self.usage = usage
        self.launcher = launcher
        self.feedback = feedback
        self.service = service
        self.clipboard = clipboard
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        let interval = Performance.begin("file.search")
        defer { Performance.end(interval) }
        statusNotice = nil
        guard isEnabled,
              case .keyword(let providerID, _, let argument) = context.mode,
              providerID == id else { return [] }
        let query = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        do {
            let result = try await service.search(query: query, timeout: .milliseconds(300))
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
        let clipboard = self.clipboard
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
                ItemAction(id: "file.open", title: "打开", symbol: "arrow.up.forward.app") {
                    do {
                        try launcher.openFile(at: hit.url)
                        usage.recordUse(of: key)
                    } catch {
                        feedback.show(error.localizedDescription)
                    }
                },
                ItemAction(id: "file.reveal", title: "在访达中显示", symbol: "folder", fileAction: .reveal) {
                    launcher.revealInFinder(hit.url)
                },
                ItemAction(id: "file.copyPath", title: "复制路径", symbol: "doc.on.doc", fileAction: .copyPath) {
                    clipboard.writeString(hit.url.path)
                    feedback.show("已复制 \(hit.url.lastPathComponent) 的路径")
                }
            ]
        )
    }
}
