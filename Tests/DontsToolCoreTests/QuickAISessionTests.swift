import Foundation
import Testing
@testable import DontsToolCore

@MainActor
private final class MockAIChatService: AIChatServicing {
    struct RecordedCall: Equatable {
        let messages: [AIChatMessage]
        let systemPrompt: String?
    }

    var isConfigured: Bool = true
    var activeModelDisplay: String = "Gemini 原生 · gemini-2.5-flash"
    var activeFormat: AIAPIFormat = .gemini
    var recordedCalls: [RecordedCall] = []

    var streamFactory: (@MainActor ([AIChatMessage], String?) -> AsyncThrowingStream<String, Error>)?

    func complete(messages: [AIChatMessage], systemPrompt: String?) async throws -> String {
        recordedCalls.append(RecordedCall(messages: messages, systemPrompt: systemPrompt))
        return "complete"
    }

    func stream(messages: [AIChatMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        recordedCalls.append(RecordedCall(messages: messages, systemPrompt: systemPrompt))
        if let factory = streamFactory {
            return factory(messages, systemPrompt)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("默认回答")
            continuation.finish()
        }
    }
}

@Suite("QuickAISession")
@MainActor
struct QuickAISessionTests {
    @Test func applyInitialRequestRespectsAutoSendAndPrefill() async {
        let service = MockAIChatService()
        service.streamFactory = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("Swift 6 ")
                continuation.yield("严格并发")
                continuation.finish()
            }
        }

        // autoSend = false prefills draft without sending
        let prefillSession = QuickAISession(service: service)
        prefillSession.applyInitialRequest(QuickAIRequest(
            title: "排查报错",
            prompt: "fatal error: index out of range",
            systemPrompt: "请分析报错",
            autoSend: false
        ))
        #expect(prefillSession.title == "排查报错")
        #expect(prefillSession.systemPrompt == "请分析报错")
        #expect(prefillSession.draftPrompt == "fatal error: index out of range")
        #expect(prefillSession.messages.isEmpty)
        #expect(service.recordedCalls.isEmpty)

        // sendDraft sends prefilled text and clears draft
        prefillSession.sendDraft()
        await prefillSession.waitForCurrentStream()
        #expect(prefillSession.draftPrompt.isEmpty)
        #expect(prefillSession.messages.count == 2)
        #expect(prefillSession.messages[0].role == .user)
        #expect(prefillSession.messages[1].content == "Swift 6 严格并发")
        #expect(!prefillSession.messages[1].isStreaming)
        #expect(!prefillSession.isStreaming)
        #expect(service.recordedCalls.first?.systemPrompt == "请分析报错")

        // autoSend = true starts immediately
        let autoSession = QuickAISession(service: service)
        autoSession.applyInitialRequest(QuickAIRequest(
            title: "解释代码",
            prompt: "解释 Sendable",
            systemPrompt: "解释概念",
            autoSend: true
        ))
        await autoSession.waitForCurrentStream()
        #expect(autoSession.messages.count == 2)
        #expect(autoSession.messages[0].content == "解释 Sendable")
        #expect(autoSession.messages[1].content == "Swift 6 严格并发")
    }

    @Test func multiTurnRegenerateAndErrorHandling() async {
        let service = MockAIChatService()
        var turn = 0
        service.streamFactory = { _, _ in
            turn += 1
            let currentTurn = turn
            return AsyncThrowingStream { continuation in
                if currentTurn == 1 {
                    continuation.yield("第一轮回答")
                    continuation.finish()
                } else if currentTurn == 2 {
                    continuation.finish(throwing: AIChatError.apiError("网络超时"))
                } else {
                    continuation.yield("重新生成成功")
                    continuation.finish()
                }
            }
        }

        let session = QuickAISession(service: service)
        session.send("问题 1")
        await session.waitForCurrentStream()
        #expect(session.messages.map(\.content) == ["问题 1", "第一轮回答"])

        // Second turn fails
        session.send("问题 2")
        await session.waitForCurrentStream()
        #expect(session.lastError == "网络超时")
        #expect(session.messages.last?.errorMessage == "网络超时")
        #expect(service.recordedCalls[1].messages == [
            AIChatMessage(role: .user, content: "问题 1"),
            AIChatMessage(role: .assistant, content: "第一轮回答"),
            AIChatMessage(role: .user, content: "问题 2")
        ])

        // Regenerate replaces failed assistant turn and succeeds
        #expect(session.canRegenerate)
        session.regenerateLast()
        await session.waitForCurrentStream()
        #expect(session.lastError == nil)
        #expect(session.messages.count == 4)
        #expect(session.messages[3].content == "重新生成成功")
        #expect(session.messages[3].errorMessage == nil)
    }

    @Test func stopStreamingAndResetPreventStaleChunksFromCorruptingState() async {
        let service = MockAIChatService()
        var savedContinuation: AsyncThrowingStream<String, Error>.Continuation?
        service.streamFactory = { _, _ in
            AsyncThrowingStream { continuation in
                savedContinuation = continuation
            }
        }

        let session = QuickAISession(service: service)
        session.send("长回答测试")
        #expect(session.isStreaming)

        savedContinuation?.yield("部分输出")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(session.messages.last?.content == "部分输出")

        // Stop streaming preserves partial output and ignores late chunks
        session.stopStreaming()
        #expect(!session.isStreaming)
        #expect(session.messages.last?.isStreaming == false)

        savedContinuation?.yield("不该被追加的旧片段")
        savedContinuation?.finish()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(session.messages.last?.content == "部分输出")

        // Reset clears everything cleanly even if a stream is active
        session.send("新对话")
        #expect(session.isStreaming)
        let secondContinuation = savedContinuation
        session.resetConversation()
        #expect(session.messages.isEmpty)
        #expect(!session.isStreaming)
        #expect(session.lastError == nil)

        secondContinuation?.yield("已重置后的脏片段")
        secondContinuation?.finish()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(session.messages.isEmpty)
    }
}
