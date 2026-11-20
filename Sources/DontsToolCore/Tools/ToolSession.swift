import Combine
import Foundation

/// One independent in-memory draft. No clipboard or window side effects live here.
@MainActor
public final class ToolSession: ObservableObject {
    public let kind: ToolKind
    @Published public var input = "" { didSet { if !input.utf8.elementsEqual(oldValue.utf8) { invalidate() } } }
    @Published public var compareLeft = "" { didSet { if !compareLeft.utf8.elementsEqual(oldValue.utf8) { invalidate() } } }
    @Published public var compareRight = "" { didSet { if !compareRight.utf8.elementsEqual(oldValue.utf8) { invalidate() } } }
    @Published public var comparing = false { didSet { if comparing != oldValue { invalidate() } } }
    @Published public var mode: String { didSet { if mode != oldValue { invalidate() } } }
    @Published public var urlSafe = false { didSet { if urlSafe != oldValue { invalidate() } } }
    @Published public var form = false { didSet { if form != oldValue { invalidate() } } }
    @Published public var bare = false { didSet { if bare != oldValue { invalidate() } } }
    @Published public var uppercase = false { didSet { if uppercase != oldValue { invalidate() } } }
    @Published public var hyphens = true { didSet { if hyphens != oldValue { invalidate() } } }
    @Published public var uuidCount = "1" { didSet { if uuidCount != oldValue { invalidate() } } }
    @Published public var unit = TimestampUnit.automatic { didSet { if unit != oldValue { invalidate() } } }
    @Published public var utc = false { didSet { if utc != oldValue { invalidate() } } }
    @Published public var target = "zh-Hans" { didSet { if target != oldValue { invalidate() } } }
    @Published public private(set) var output = ""
    @Published public private(set) var comparison: JSONComparison?
    @Published public private(set) var timestamp: TimestampResult?
    @Published public private(set) var isRunning = false
    @Published public private(set) var isFresh = false
    @Published public private(set) var hasResult = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var errorRange: NSRange?
    @Published public private(set) var errorSide: String?
    @Published public private(set) var status = "就绪"
    @Published public private(set) var pendingRequest: ToolOpenRequest?
    private var revision = 0
    private var task: Task<Void, Never>?
    private var committingText = false
    private let translator: TranslationServicing?
    public var canCopy: Bool { isFresh && !isRunning && !(kind == .json && comparing) }
    public var hasStaleResult: Bool { hasResult && !isFresh }
    public var editsTextInPlace: Bool { kind == .base64 || kind == .url || (kind == .json && !comparing) }
    public var translationConfigured: Bool { translator?.isConfigured == true }
    public var primaryTitle: String {
        if kind == .json && comparing { return "对比" }
        switch kind {
        case .json:
            switch mode { case "minify": return "压缩"; case "escape": return "转义"; case "unescape": return "去转义"; default: return "格式化" }
        case .base64, .url: return mode == "decode" ? "解码" : "编码"
        case .hash: return "计算哈希"
        case .uuid: return "重新生成"
        case .timestamp: return "转换"
        case .translation: return "翻译"
        }
    }
    public init(kind: ToolKind, translator: TranslationServicing? = nil) {
        self.kind = kind; self.translator = translator; self.mode = kind.defaultMode
        if kind == .uuid { output = UUID().uuidString.lowercased(); isFresh = true; hasResult = true; status = "已生成 1 条 UUID v4" }
    }
    /// Copy editable state without inheriting results, pending requests, or running work.
    public func cloneDraft() -> ToolSession {
        let copy = ToolSession(kind: kind, translator: translator)
        copy.input = input
        copy.compareLeft = compareLeft
        copy.compareRight = compareRight
        copy.comparing = comparing
        copy.mode = mode
        copy.urlSafe = urlSafe
        copy.form = form
        copy.bare = bare
        copy.uppercase = uppercase
        copy.hyphens = hyphens
        copy.uuidCount = uuidCount
        copy.unit = unit
        copy.utc = utc
        copy.target = target
        return copy
    }
    private func invalidate() {
        guard !committingText else { return }
        revision &+= 1
        task?.cancel(); task = nil
        isRunning = false; isFresh = false
        errorMessage = nil; errorRange = nil; errorSide = nil
        status = hasResult ? (editsTextInPlace ? "内容已更改" : "输入已更改，需重新处理") : "就绪"
    }
    public func accept(_ request: ToolOpenRequest) {
        guard request.kind == kind else { return }
        if let new = request.input, !new.isEmpty, !input.isEmpty, !new.utf8.elementsEqual(input.utf8) {
            pendingRequest = request; return
        }
        apply(request)
    }
    private func apply(_ request: ToolOpenRequest) {
        if let mode = request.mode { self.mode = mode }
        guard let text = request.input else { return }
        if kind == .json && request.mode == "format" && !comparing {
            input = (try? TextTransformers.formatJSON(text, pretty: true)) ?? text
        } else {
            input = text
        }
    }
    public func resolvePending(useNew: Bool) {
        let request = pendingRequest; pendingRequest = nil
        if useNew, let request { apply(request) }
    }
    public func cancel() {
        guard task != nil || isRunning else { return }
        revision &+= 1; task?.cancel(); task = nil
        isRunning = false; status = "已取消"; isFresh = false
    }
    public func run() {
        run(committingText: nil)
    }
    func run(committingText: (@MainActor (String) -> Void)?) {
        // Supersede synchronously so an old completion cannot clear the newly queued handle.
        revision &+= 1
        task?.cancel()
        task = Task { [weak self] in await self?.perform(committingText: committingText) }
    }
    public func perform() async {
        await perform(committingText: nil)
    }
    private func perform(committingText commit: (@MainActor (String) -> Void)?) async {
        guard !Task.isCancelled else { return }
        revision &+= 1
        let version = revision
        let snapshot = OperationSnapshot(session: self)
        isRunning = true; isFresh = false; errorMessage = nil; errorRange = nil; errorSide = nil; status = "正在\(primaryTitle)…"
        defer { if revision == version { isRunning = false; task = nil } }
        do {
            let result: OperationOutput
            if kind == .translation {
                guard let translator, translator.isConfigured else { throw ActionError.translationFailed("翻译 API 未配置，请先打开设置填写接口、模型和密钥") }
                guard !snapshot.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ActionError.invalidInput("请输入要翻译的文本") }
                result = OperationOutput(text: try await translator.translate(snapshot.input, target: snapshot.target))
            } else {
                let work = Task.detached(priority: .userInitiated) { try snapshot.execute() }
                result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            }
            guard revision == version, !Task.isCancelled else { return }
            if commit != nil, result.text.utf8.count > ToolOperations.textByteLimit {
                throw ActionError.invalidInput("处理后的文本超过 2 MiB 编辑限制，请减少内容后重试；原文已保留")
            }
            output = result.text; comparison = result.comparison; timestamp = result.timestamp
            hasResult = true
            isFresh = true
            if let comparison {
                status = comparison.total == 0 ? "无结构差异" : "新增 \(comparison.added) · 删除 \(comparison.removed) · 修改 \(comparison.modified)"
                if comparison.total > 1000 { status += " · 显示前 1000 项，共 \(comparison.total) 项" }
            } else if kind == .uuid { status = "已生成 \(output.split(separator: "\n").count) 条 UUID v4" }
            else { status = "\(primaryTitle)完成" }
            if let commit {
                // The validated result is now the editable document, not a new user revision.
                committingText = true
                commit(result.text)
                committingText = false
            }
        } catch {
            guard revision == version, !Task.isCancelled else { return }
            if error is CancellationError { status = "已取消"; return }
            errorMessage = error.localizedDescription; status = "处理失败"
            if let issue = error as? JSONIssue { errorRange = issue.range }
            if let issue = error as? JSONSideIssue {
                errorSide = issue.side; errorRange = (issue.underlying as? JSONIssue)?.range
            }
        }
    }
}
