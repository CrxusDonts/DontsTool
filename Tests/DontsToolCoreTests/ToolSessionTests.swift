import Foundation
import Testing
@testable import DontsToolCore

@Suite("工具会话") @MainActor
struct ToolSessionTests {
    @Test func byteDistinctUnicodeInvalidatesResult() async {
        let session = ToolSession(kind: .base64)
        session.input = "\u{e9}"
        await session.perform()
        #expect(session.output == "w6k=")
        #expect(session.canCopy)
        session.input = "e\u{301}"
        #expect(!session.canCopy)
        await session.perform()
        #expect(session.output == "ZcyB")
    }
    @Test func resultFreshnessAndDraftProtection() async throws {
        let session = ToolSession(kind: .base64)
        session.input = "hello"
        await session.perform()
        #expect(session.output == "aGVsbG8=")
        #expect(session.canCopy)
        session.input = "world"
        #expect(!session.canCopy)
        session.accept(ToolOpenRequest(kind: .base64, mode: "decode", input: "aGk="))
        #expect(session.input == "world")
        #expect(session.pendingRequest != nil)
        session.resolvePending(useNew: false)
        #expect(session.mode == "encode")
        session.accept(ToolOpenRequest(kind: .base64, mode: "decode", input: "aGk="))
        session.resolvePending(useNew: true)
        await session.perform()
        #expect(session.output == "hi")
    }
    @Test func failuresRetainInputAndInvalidateOutput() async {
        let session = ToolSession(kind: .json)
        session.input = "true"
        await session.perform()
        #expect(session.output == "true")
        session.input = "{broken"
        await session.perform()
        #expect(session.input == "{broken")
        #expect(!session.canCopy)
        #expect(session.errorMessage != nil)
    }
    @Test func failedRerunKeepsPreviousResultExplicitlyStale() async {
        let session = ToolSession(kind: .json)
        #expect(!session.hasStaleResult)
        session.input = "true"
        await session.perform()
        #expect(!session.hasStaleResult)
        session.input = "{broken"
        await session.perform()
        #expect(session.output == "true")
        #expect(session.hasStaleResult)
        #expect(!session.canCopy)
        #expect(session.errorMessage != nil)
    }
    @Test func successfulEmptyResultStillBecomesStaleAfterEdit() async {
        let session = ToolSession(kind: .base64)
        await session.perform()
        #expect(session.output.isEmpty)
        #expect(session.canCopy)
        session.input = "hello"
        #expect(session.hasStaleResult)
        await session.perform()
        #expect(!session.hasStaleResult)
    }
    @Test func failedFirstRunDoesNotClaimRetainedResult() async {
        let session = ToolSession(kind: .json)
        session.input = "{broken"
        await session.perform()
        #expect(!session.hasStaleResult)
    }
    @Test func UUIDReopenDoesNotRegenerate() {
        let session = ToolSession(kind: .uuid)
        let value = session.output
        session.accept(ToolOpenRequest(kind: .uuid))
        #expect(session.output == value)
        #expect(UUID(uuidString: value) != nil)
    }
    @Test func cancelledTranslationCannotPublishOldResponse() async {
        let translator = SuspendedTranslator()
        let session = ToolSession(kind: .translation, translator: translator)
        session.input = "one"
        let old = Task { await session.perform() }
        while translator.continuation == nil { await Task.yield() }
        session.input = "two"
        translator.continuation?.resume(returning: "旧译文")
        await old.value
        #expect(session.output.isEmpty)
        #expect(!session.canCopy)
        #expect(!session.isRunning)
    }
    @Test func cancelledPendingRunDoesNotSendTranslationRequest() async {
        let translator = PendingRunTranslator()
        let session = ToolSession(kind: .translation, translator: translator)
        session.input = "must stay local"
        session.run()
        session.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(translator.inputs.isEmpty)
        #expect(session.output.isEmpty)
        #expect(!session.isRunning)
    }
    @Test func replacingRunningOperationKeepsNewCancellationHandle() async {
        let translator = RerunTranslator()
        let session = ToolSession(kind: .translation, translator: translator)
        session.input = "retry"
        session.run()
        while translator.continuation == nil { await Task.yield() }
        translator.finish()
        session.run()
        while translator.started != 2 { await Task.yield() }
        session.cancel()
        translator.finish()
        while translator.finished != 2 { await Task.yield() }
        #expect(translator.cancelled == 2)
        #expect(session.output.isEmpty)
    }
}
@MainActor private final class SuspendedTranslator: TranslationServicing {
    var isConfigured = true
    var continuation: CheckedContinuation<String, Never>?
    func translate(_ text: String, target: String) async throws -> String {
        await withCheckedContinuation { continuation = $0 }
    }
}
@MainActor private final class PendingRunTranslator: TranslationServicing {
    var isConfigured = true
    var inputs: [String] = []
    func translate(_ text: String, target: String) async throws -> String {
        inputs.append(text)
        return "unexpected"
    }
}
@MainActor private final class RerunTranslator: TranslationServicing {
    var isConfigured = true
    var started = 0
    var finished = 0
    var cancelled = 0
    var continuation: CheckedContinuation<String, Never>?
    func translate(_ text: String, target: String) async throws -> String {
        started += 1
        let result = await withCheckedContinuation { continuation = $0 }
        finished += 1
        if Task.isCancelled { cancelled += 1 }
        return result
    }
    func finish() {
        let current = continuation
        continuation = nil
        current?.resume(returning: "response")
    }
}
