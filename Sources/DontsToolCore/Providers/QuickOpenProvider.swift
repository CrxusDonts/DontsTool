import Foundation

/// 识别直接输入的网址或已存在路径，回车打开。
@MainActor
public final class QuickOpenProvider: ToolProvider {
    public let id = ProviderID.quickOpen.rawValue
    public let displayName = "打开网址或路径"
    public let keywords = ["open"]
    public let priority = 280
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }

    private let settings: SettingsStore
    private let usage: UsageStore
    private let launcher: any AppLaunching
    private let opener: any URLOpening
    private let clipboard: any ClipboardProviding
    private let feedback: any FeedbackProviding
    private let openInTerminal: (@MainActor (URL) async throws -> Void)?
    private let fileExists: (String) -> Bool

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        settings: SettingsStore,
        usage: UsageStore,
        launcher: any AppLaunching,
        opener: any URLOpening,
        clipboard: any ClipboardProviding,
        feedback: any FeedbackProviding,
        openInTerminal: (@MainActor (URL) async throws -> Void)? = nil,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.settings = settings
        self.usage = usage
        self.launcher = launcher
        self.opener = opener
        self.clipboard = clipboard
        self.feedback = feedback
        self.openInTerminal = openInTerminal
        self.fileExists = fileExists
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled else { return [] }
        switch context.mode {
        case .keyword(let providerID, _, _) where providerID == id:
            let argument = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !argument.isEmpty else { return [hintItem()] }
            guard let target = QuickOpenParser.parse(argument, fileExists: fileExists) else {
                return [hintItem(title: "无法识别网址或路径")]
            }
            return [item(for: target)]
        case .global:
            guard let target = QuickOpenParser.parse(context.query, fileExists: fileExists) else { return [] }
            return [item(for: target)]
        default:
            return []
        }
    }

    private func item(for target: QuickOpenTarget) -> SearchItem {
        switch target {
        case .url(let url):
            return urlItem(url)
        case .file(let url):
            return fileItem(url)
        }
    }

    private func urlItem(_ url: URL) -> SearchItem {
        let opener = self.opener
        let usage = self.usage
        let clipboard = self.clipboard
        let feedback = self.feedback
        let key = "quickopen:url:\(url.absoluteString)"
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "打开网址",
            subtitle: url.absoluteString,
            icon: .symbol(name: "globe", tint: .blue),
            score: 2600,
            canonicalKey: key,
            actions: [
                ItemAction(id: "quickopen.url.open", title: "打开", symbol: "arrow.up.forward.app") {
                    do {
                        try opener.open(url)
                        usage.recordUse(of: key)
                    } catch {
                        feedback.show(error.localizedDescription)
                    }
                },
                ItemAction(id: "quickopen.url.copy", title: "复制链接", symbol: "link") {
                    clipboard.writeString(url.absoluteString)
                    feedback.show("已复制链接")
                }
            ]
        )
    }

    private func fileItem(_ url: URL) -> SearchItem {
        let launcher = self.launcher
        let usage = self.usage
        let clipboard = self.clipboard
        let feedback = self.feedback
        let openInTerminal = self.openInTerminal
        let key = "quickopen:file:\(url.path)"
        var actions: [ItemAction] = [
            ItemAction(id: "quickopen.file.open", title: "打开", symbol: "arrow.up.forward.app") {
                do {
                    try launcher.openFile(at: url)
                    usage.recordUse(of: key)
                } catch {
                    feedback.show(error.localizedDescription)
                }
            },
            ItemAction(id: "quickopen.file.reveal", title: "在访达中显示", symbol: "folder", fileAction: .reveal) {
                launcher.revealInFinder(url)
            },
            ItemAction(id: "quickopen.file.copy", title: "复制路径", symbol: "doc.on.doc", fileAction: .copyPath) {
                clipboard.writeString(url.path)
                feedback.show("已复制 \(url.lastPathComponent) 的路径")
            }
        ]
        if let openInTerminal {
            actions.append(ItemAction(id: "quickopen.file.openInTerminal", title: "在终端中打开", presentation: .openWindow, symbol: "terminal") {
                do {
                    try await openInTerminal(url)
                } catch {
                    feedback.show(error.localizedDescription)
                }
            })
        }
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "打开 \(url.lastPathComponent)",
            subtitle: PathDisplay.parentDirectory(of: url),
            icon: .file(path: url.path),
            score: 2600,
            canonicalKey: key,
            actions: actions
        )
    }

    private func hintItem(title: String = "打开网址或路径") -> SearchItem {
        let feedback = self.feedback
        return SearchItem(
            providerID: id,
            group: .tool,
            title: title,
            subtitle: "支持 https://、www.、~/ 和绝对路径",
            icon: .symbol(name: "arrow.up.forward.app", tint: .blue),
            score: 1200,
            canonicalKey: "quickopen:hint",
            actions: [
                ItemAction(id: "quickopen.hint", title: "提示", presentation: .keepPanelOpen, symbol: "info.circle") {
                    feedback.show("请输入网址或已存在的绝对路径")
                }
            ],
            keyword: "open"
        )
    }
}
