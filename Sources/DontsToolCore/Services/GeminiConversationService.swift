import Foundation

public struct GeminiComposerState: Equatable, Sendable {
    public let text: String?
    public let isNewConversation: Bool
    public let isFrontmost: Bool
    public let canSend: Bool
    public let submissionAccepted: Bool

    public init(text: String?, isNewConversation: Bool, isFrontmost: Bool, canSend: Bool,
                submissionAccepted: Bool = false) {
        self.text = text
        self.isNewConversation = isNewConversation
        self.isFrontmost = isFrontmost
        self.canSend = canSend
        self.submissionAccepted = submissionAccepted
    }
}

@MainActor
public protocol GeminiAppControlling: AnyObject {
    var canAutomate: Bool { get }
    func open(_ application: URL) async throws
    func newConversation() async throws
    func readComposer() async throws -> GeminiComposerState
    func setPrompt(_ question: String) async throws
    func submit() async throws
    func finishHandoff()
}

extension GeminiAppControlling {
    public func finishHandoff() {}
}

@MainActor
public protocol GeminiAsking: AnyObject {
    func ask(_ question: String, in application: URL) async throws
    func open(in application: URL) async throws
}

@MainActor
public final class GeminiConversationService: GeminiAsking {
    public static let applicationBundleIdentifier = "com.google.GeminiMacOS"
    public static let maximumQuestionLength = 32_768
    private let controller: any GeminiAppControlling
    private let pollInterval: Duration
    private let maximumAttempts: Int
    private let maximumWait: Duration
    private var isBusy = false

    public init(controller: any GeminiAppControlling, pollInterval: Duration = .milliseconds(80),
                maximumAttempts: Int = 60, maximumWait: Duration = .seconds(8)) {
        self.controller = controller
        self.pollInterval = pollInterval
        self.maximumAttempts = max(1, maximumAttempts)
        self.maximumWait = maximumWait
    }

    public func open(in application: URL) async throws {
        guard !isBusy else { throw ActionError.invalidInput("Gemini 正在处理上一条问题，请稍候") }
        isBusy = true
        defer { isBusy = false }
        try await controller.open(application)
    }

    public func ask(_ question: String, in application: URL) async throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActionError.invalidInput("请在 gm 后输入问题")
        }
        guard question.utf16.count <= Self.maximumQuestionLength else {
            throw ActionError.invalidInput("问题过长，请直接在 Gemini 中编辑")
        }
        guard !isBusy else { throw ActionError.invalidInput("Gemini 正在处理上一条问题，请稍候") }
        guard controller.canAutomate else {
            throw ActionError.invalidInput("自动提问需要 DontsTool 的辅助功能权限，也可选择仅打开 Gemini")
        }
        isBusy = true
        defer { isBusy = false; controller.finishHandoff() }
        try Task.checkCancellation()
        try await controller.open(application)
        let existing = try await waitForComposer(awaitingInitialActivation: true) { $0.text != nil }
        guard existing.text == "" else {
            throw ActionError.invalidInput("Gemini 有未发送的草稿，请先处理；已保留原文")
        }
        try Task.checkCancellation()
        try await controller.newConversation()
        _ = try await waitForComposer { $0.isNewConversation && $0.text == "" }
        try Task.checkCancellation()
        try await controller.setPrompt(question)
        _ = try await waitForComposer { state in
            guard state.text == question else {
                throw ActionError.invalidInput("Gemini 未完整接收问题，已停止自动发送，请检查输入框")
            }
            guard state.isNewConversation else {
                throw ActionError.invalidInput("Gemini 已离开新对话，已停止自动发送")
            }
            return state.canSend
        }
        try Task.checkCancellation()
        try await controller.submit()
        _ = try await waitForComposer(confirmingSubmission: true) { $0.submissionAccepted }
    }

    private func waitForComposer(awaitingInitialActivation: Bool = false, confirmingSubmission: Bool = false,
                                 _ ready: (GeminiComposerState) throws -> Bool) async throws -> GeminiComposerState {
        var awaitingActivation = awaitingInitialActivation
        let deadline = ContinuousClock.now.advanced(by: maximumWait)
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { break }
            let state = try await controller.readComposer()
            guard ContinuousClock.now < deadline else { break }
            if state.isFrontmost || confirmingSubmission {
                if state.isFrontmost { awaitingActivation = false }
                if try ready(state) { return state }
            } else if !awaitingActivation {
                throw ActionError.invalidInput("已离开 Gemini，自动提问已取消")
            }
            if attempt + 1 < maximumAttempts { try await Task.sleep(for: pollInterval) }
        }
        throw ActionError.invalidInput(confirmingSubmission
            ? "Gemini 已执行发送，但尚未确认结果，请在应用中查看；不会重复发送"
            : "Gemini 尚未就绪或界面已变化，已停止自动操作，请在应用中查看")
    }
}
