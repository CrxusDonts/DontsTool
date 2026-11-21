import Combine
import Foundation

@MainActor
public final class QuickAISession: ObservableObject, Identifiable {
    public let id: UUID

    @Published public var title: String
    @Published public var systemPrompt: String?
    @Published public private(set) var messages: [QuickAIMessage] = []
    @Published public var draftPrompt: String = ""
    @Published public private(set) var isStreaming: Bool = false
    @Published public var isPinned: Bool = false
    @Published public private(set) var lastError: String?

    private let service: any AIChatServicing
    private var generation: UInt64 = 0
    private var streamTask: Task<Void, Never>?

    public init(
        id: UUID = UUID(),
        title: String = "AI 快问",
        systemPrompt: String? = nil,
        service: any AIChatServicing
    ) {
        self.id = id
        self.title = title
        self.systemPrompt = systemPrompt
        self.service = service
    }

    public var isConfigured: Bool {
        service.isConfigured
    }

    public var activeModelDisplay: String {
        service.activeModelDisplay
    }

    public var activeFormat: AIAPIFormat {
        service.activeFormat
    }

    public var canRegenerate: Bool {
        !isStreaming && messages.contains(where: { $0.role == .user })
    }

    public var lastAssistantContent: String? {
        messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content
    }

    public func applyInitialRequest(_ request: QuickAIRequest) {
        stopStreaming()
        if let reqTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !reqTitle.isEmpty {
            title = reqTitle
        }
        if let reqSystem = request.systemPrompt {
            let trimmedSystem = reqSystem.trimmingCharacters(in: .whitespacesAndNewlines)
            systemPrompt = trimmedSystem.isEmpty ? nil : trimmedSystem
        }
        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty {
            draftPrompt = ""
            return
        }
        if request.autoSend {
            draftPrompt = ""
            send(trimmedPrompt)
        } else {
            draftPrompt = trimmedPrompt
        }
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopStreaming()
        lastError = nil

        messages.append(QuickAIMessage(role: .user, content: trimmed))
        let history = buildRequestMessages()
        startStreamingResponse(history: history)
    }

    public func sendDraft() {
        let trimmed = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draftPrompt = ""
        send(trimmed)
    }

    public func stopStreaming() {
        generation &+= 1
        streamTask?.cancel()
        streamTask = nil
        if isStreaming {
            isStreaming = false
        }
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
        }
    }

    public func regenerateLast() {
        stopStreaming()
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return
        }
        if lastUserIndex + 1 < messages.count {
            messages.removeSubrange((lastUserIndex + 1)..<messages.count)
        }
        lastError = nil
        let history = buildRequestMessages()
        startStreamingResponse(history: history)
    }

    public func resetConversation() {
        stopStreaming()
        messages = []
        draftPrompt = ""
        lastError = nil
    }

    public func waitForCurrentStream() async {
        await streamTask?.value
    }

    // MARK: - Private

    private func buildRequestMessages() -> [AIChatMessage] {
        messages.compactMap { message in
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AIChatMessage(role: message.role, content: message.content)
        }
    }

    private func startStreamingResponse(history: [AIChatMessage]) {
        let assistantMessage = QuickAIMessage(role: .assistant, content: "", isStreaming: true)
        let assistantID = assistantMessage.id
        messages.append(assistantMessage)

        generation &+= 1
        let activeGeneration = generation
        isStreaming = true

        let promptSystem = systemPrompt
        let stream = service.stream(messages: history, systemPrompt: promptSystem)

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await delta in stream {
                    guard self.generation == activeGeneration, !Task.isCancelled else { return }
                    guard !delta.isEmpty,
                          let index = self.messages.firstIndex(where: { $0.id == assistantID }) else {
                        continue
                    }
                    self.messages[index].content.append(delta)
                }

                guard self.generation == activeGeneration else { return }
                self.isStreaming = false
                self.streamTask = nil
                if let index = self.messages.firstIndex(where: { $0.id == assistantID }) {
                    self.messages[index].isStreaming = false
                    if self.messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       self.messages[index].errorMessage == nil {
                        let emptyMessage = AIChatError.emptyResponse.localizedDescription
                        self.messages[index].errorMessage = emptyMessage
                        self.lastError = emptyMessage
                    }
                }
            } catch is CancellationError {
                guard self.generation == activeGeneration else { return }
                self.isStreaming = false
                self.streamTask = nil
                if let index = self.messages.firstIndex(where: { $0.id == assistantID }) {
                    self.messages[index].isStreaming = false
                }
            } catch {
                guard self.generation == activeGeneration else { return }
                let errorMessage = error.localizedDescription
                self.isStreaming = false
                self.streamTask = nil
                self.lastError = errorMessage
                if let index = self.messages.firstIndex(where: { $0.id == assistantID }) {
                    self.messages[index].isStreaming = false
                    self.messages[index].errorMessage = errorMessage
                }
                Log.ai.error("Quick AI 流式回答失败：\(errorMessage, privacy: .public)")
            }
        }
    }
}
