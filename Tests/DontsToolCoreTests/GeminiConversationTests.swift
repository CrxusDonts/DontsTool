import Foundation
import Testing
@testable import DontsToolCore

@Suite("Gemini conversation handoff")
@MainActor
struct GeminiConversationTests {
    private let app = URL(fileURLWithPath: "/Applications/Gemini.app")
    private func service(_ control: GeminiTestController) -> GeminiConversationService {
        GeminiConversationService(controller: control, pollInterval: .zero, maximumAttempts: 3)
    }

    @Test func opensANewConversationAndSubmitsTheOriginalQuestionOnce() async throws {
        let control = GeminiTestController()
        let question = "解释 Swift actor\n保留这行和空格  "
        try await service(control).ask(question, in: app)
        #expect(control.events == ["open", "new", "write", "submit"])
        #expect(control.written == question)
        #expect(control.application == app)
        #expect(control.submissions == 1)
    }

    @Test func anExistingDraftIsNeverOverwrittenOrSubmitted() async {
        let control = GeminiTestController()
        control.text = "用户尚未发送的草稿"
        await #expect(throws: Error.self) { try await service(control).ask("测试", in: app) }
        #expect(control.events == ["open"])
        #expect(control.text == "用户尚未发送的草稿")
        #expect(control.submissions == 0)
    }

    @Test func failedNewConversationNeverWritesIntoTheOldConversation() async {
        let control = GeminiTestController()
        control.newConversationWorks = false
        await #expect(throws: Error.self) { try await service(control).ask("测试", in: app) }
        #expect(control.written == nil)
        #expect(control.submissions == 0)
    }

    @Test func changedOrTruncatedInputIsNeverSent() async {
        let control = GeminiTestController()
        control.truncateWrites = true
        await #expect(throws: Error.self) { try await service(control).ask("完整的问题", in: app) }
        #expect(control.submissions == 0)
    }

    @Test func switchingAppsBeforeSubmitStopsTheHandoff() async {
        let control = GeminiTestController()
        control.loseFocusAfterWrite = true
        await #expect(throws: Error.self) { try await service(control).ask("测试", in: app) }
        #expect(control.submissions == 0)
    }

    @Test func missingPermissionDoesNotStartAutomationButBasicOpenStillWorks() async throws {
        let control = GeminiTestController()
        control.canAutomate = false
        let bridge = service(control)
        await #expect(throws: Error.self) { try await bridge.ask("测试", in: app) }
        #expect(control.events.isEmpty)
        try await bridge.open(in: app)
        #expect(control.events == ["open"])
    }

    @Test(arguments: ["", "  \n ", String(repeating: "x", count: 32_769)])
    func invalidInputDoesNotOpenOrSend(_ question: String) async {
        let control = GeminiTestController()
        await #expect(throws: Error.self) { try await service(control).ask(question, in: app) }
        #expect(control.events.isEmpty)
    }

    @Test func cancellationAfterWritingNeverSubmits() async {
        let control = GeminiTestController()
        control.pauseAfterWrite = true
        let bridge = service(control)
        let task = Task { try await bridge.ask("测试", in: app) }
        while control.written == nil { await Task.yield() }
        task.cancel()
        _ = await task.result
        #expect(control.submissions == 0)
        #expect(control.finishes == 1)
    }

    @Test func aBasicOpenCannotRaceWithAnotherHandoff() async throws {
        let control = GeminiTestController()
        control.pauseOpening = true
        let bridge = service(control)
        let opening = Task { try await bridge.open(in: app) }
        while control.openingWaiter == nil { await Task.yield() }
        await #expect(throws: Error.self) { try await bridge.ask("不能并发发送", in: app) }
        control.openingWaiter?.resume()
        try await opening.value
        #expect(control.events == ["open"])
        #expect(control.submissions == 0)
    }
}

@MainActor
private final class GeminiTestController: GeminiAppControlling {
    var canAutomate = true
    var text = ""
    var isNew = false
    var active = true
    var newConversationWorks = true
    var truncateWrites = false
    var loseFocusAfterWrite = false
    var pauseAfterWrite = false
    var pauseOpening = false
    var openingWaiter: CheckedContinuation<Void, Never>?
    var finishes = 0
    var written: String?
    var application: URL?
    var submissions = 0
    var events: [String] = []
    func open(_ application: URL) async throws {
        self.application = application; events.append("open")
        if pauseOpening {
            pauseOpening = false
            await withCheckedContinuation { openingWaiter = $0 }
        }
    }
    func finishHandoff() { finishes += 1 }
    func newConversation() async throws { events.append("new"); if newConversationWorks { isNew = true } }
    func readComposer() async throws -> GeminiComposerState {
        GeminiComposerState(text: text, isNewConversation: isNew, isFrontmost: active,
                            canSend: !text.isEmpty, submissionAccepted: submissions > 0 && text.isEmpty)
    }
    func setPrompt(_ question: String) async throws {
        events.append("write"); written = question; text = truncateWrites ? "截断" : question
        if loseFocusAfterWrite { active = false }
        if pauseAfterWrite { try await Task.sleep(for: .seconds(10)) }
    }
    func submit() async throws { events.append("submit"); submissions += 1; text = ""; isNew = false }
}
