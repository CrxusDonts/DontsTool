import Foundation
import Testing

@Suite("Gemini native accessibility handoff")
struct GeminiAppAccessibilityTests {
    @Test func committedSendCanBeAcknowledgedFromItsBoundWindowInBackground() throws {
        let ax = GeminiAXFixture()
        var session = GeminiAXSession(ax: ax, pid: 42)
        try session.write("question")
        try session.submit()
        ax.frontmostPID = 99
        ax.nodes["prompt"]!.text = ""
        ax.nodes["window"]!.children.append("share")
        ax.nodes["share"] = .init(role: "AXButton", identifier: "share_button")
        let state = try session.read()
        #expect(state.submissionAccepted)
        #expect(!state.isFrontmost)
        #expect(ax.presses == ["send"])
        #expect(throws: Error.self) { try session.write("another question") }
        #expect(throws: Error.self) { try session.submit() }
    }

    @Test func backgroundAcknowledgementCannotRebindToAnotherWindow() throws {
        let ax = GeminiAXFixture()
        var session = GeminiAXSession(ax: ax, pid: 42)
        try session.write("question")
        try session.submit()
        ax.frontmostPID = 99
        ax.nodes["other"] = ax.nodes["window"]
        ax.focused = "other"
        #expect(throws: Error.self) { try session.read() }
        #expect(ax.presses == ["send"])
    }

    @Test func readsOnlyTheRecognizedComposerAndSkipsChatHistory() throws {
        let ax = GeminiAXFixture()
        ax.nodes["history"] = .init(role: "AXList", children: ["private"])
        ax.nodes["private"] = .init(role: "AXTextArea", description: "Ask Gemini", text: "private history")
        ax.nodes["window"]!.children.insert("history", at: 0)
        var session = GeminiAXSession(ax: ax, pid: 42)
        let state = try session.read()
        #expect(state.text == "")
        #expect(state.isNewConversation)
        #expect(ax.valueReads == ["prompt"])
        #expect(!ax.metadataReads.contains("private"))
    }

    @Test func anOldConversationIsNeverMistakenForTheNewChatLanding() throws {
        let ax = GeminiAXFixture()
        ax.nodes["window"]!.children.append("share")
        ax.nodes["share"] = .init(role: "AXButton", identifier: "share_button")
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(try !session.read().isNewConversation)
    }

    @Test func preservesAnExistingDraft() throws {
        let ax = GeminiAXFixture()
        ax.nodes["prompt"]!.text = "unfinished draft"
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(throws: Error.self) { try session.write("new question") }
        #expect(ax.nodes["prompt"]!.text == "unfinished draft")
        #expect(ax.writes.isEmpty)
    }

    @Test func switchingApplicationsBeforeWritingOrSubmittingPreventsTheAction() throws {
        let ax = GeminiAXFixture()
        var session = GeminiAXSession(ax: ax, pid: 42)
        _ = try session.read()
        ax.frontmostPID = 99
        #expect(throws: Error.self) { try session.write("question") }
        #expect(ax.writes.isEmpty)
        ax.frontmostPID = 42
        try session.write("question")
        ax.frontmostPID = 99
        #expect(throws: Error.self) { try session.submit() }
        #expect(ax.presses.isEmpty)
    }

    @Test func switchingWindowsCannotRedirectThePrompt() throws {
        let ax = GeminiAXFixture()
        var session = GeminiAXSession(ax: ax, pid: 42)
        _ = try session.read()
        ax.focused = "other"
        ax.nodes["other"] = ax.nodes["window"]
        #expect(throws: Error.self) { try session.write("question") }
        #expect(ax.writes.isEmpty)
    }

    @Test func changedInputCannotBeSubmitted() throws {
        let ax = GeminiAXFixture()
        var session = GeminiAXSession(ax: ax, pid: 42)
        try session.write("完整的问题\n保留空格  ")
        ax.nodes["prompt"]!.text = "changed"
        #expect(throws: Error.self) { try session.submit() }
        #expect(ax.presses.isEmpty)
    }

    @Test func pressingSendIsNotAcceptanceAndCannotBeRepeated() throws {
        let ax = GeminiAXFixture()
        var session = GeminiAXSession(ax: ax, pid: 42)
        try session.write("question")
        try session.submit()
        #expect(try !session.read().submissionAccepted)
        #expect(throws: Error.self) { try session.submit() }
        #expect(ax.presses == ["send"])
        ax.nodes["prompt"]!.text = ""
        #expect(try !session.read().submissionAccepted)
        ax.nodes["window"]!.children.append("share")
        ax.nodes["share"] = .init(role: "AXButton", identifier: "share_button")
        #expect(try session.read().submissionAccepted)
    }

    @Test func anUnsentEmptyConversationCannotReportAcceptance() throws {
        let ax = GeminiAXFixture()
        ax.nodes["window"]!.children.append("share")
        ax.nodes["share"] = .init(role: "AXButton", identifier: "share_button")
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(try !session.read().submissionAccepted)
    }

    @Test func anAmbiguousComposerDoesNotReadOrWriteEitherPrompt() throws {
        let ax = GeminiAXFixture()
        ax.nodes["duplicate"] = ax.nodes["prompt"]
        ax.nodes["window"]!.children.append("duplicate")
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(throws: Error.self) { try session.write("question") }
        #expect(ax.valueReads.isEmpty)
        #expect(ax.writes.isEmpty)
    }

    @Test func unavailablePermissionDoesNotInspectTheApplication() {
        let ax = GeminiAXFixture()
        ax.trusted = false
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(throws: Error.self) { try session.read() }
        #expect(ax.metadataReads.isEmpty)
        #expect(ax.valueReads.isEmpty)
    }

    @Test func permissionRevocationWhileInspectingPreventsWriting() throws {
        let ax = GeminiAXFixture()
        ax.beforeTextRead = { ax.trusted = false }
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(throws: Error.self) { try session.write("question") }
        #expect(ax.writes.isEmpty)
    }

    @Test func anUnacknowledgedPressIsNeverRetried() throws {
        let ax = GeminiAXFixture()
        ax.pressSucceeds = false
        var session = GeminiAXSession(ax: ax, pid: 42)
        try session.write("question")
        #expect(throws: Error.self) { try session.submit() }
        #expect(throws: Error.self) { try session.submit() }
        #expect(ax.presses == ["send"])
    }

    @Test func disabledSendCannotBePressed() throws {
        let ax = GeminiAXFixture()
        ax.nodes["send"]!.enabled = false
        var session = GeminiAXSession(ax: ax, pid: 42)
        try session.write("question")
        #expect(throws: Error.self) { try session.submit() }
        #expect(ax.presses.isEmpty)
    }

    @Test func newConversationPreparationPreservesDraftsAndAllowsOnlyAnEmptyWindowRebind() throws {
        let ax = GeminiAXFixture()
        var session = GeminiAXSession(ax: ax, pid: 42)
        ax.nodes["prompt"]!.text = "draft"
        #expect(throws: Error.self) { try session.prepareForNewConversation() }
        ax.focused = "other"
        ax.nodes["other"] = ax.nodes["window"]
        #expect(throws: Error.self) { try session.read() }
        ax.focused = "window"
        ax.nodes["prompt"]!.text = ""
        try session.prepareForNewConversation()
        ax.focused = "other"
        #expect(try session.read().isNewConversation)
    }

    @Test func anOldWindowDuringNewChatLoadingDoesNotBindTheNextOperationToThatWindow() throws {
        let ax = GeminiAXFixture()
        ax.nodes["window"]!.children.append("share")
        ax.nodes["share"] = .init(role: "AXButton", identifier: "share_button")
        var session = GeminiAXSession(ax: ax, pid: 42)
        try session.prepareForNewConversation()
        #expect(try !session.read().isNewConversation)
        ax.nodes["other"] = .init(role: "AXWindow", children: ["temporary", "prompt", "send"])
        ax.focused = "other"
        #expect(try session.read().isNewConversation)
        try session.write("question")
        #expect(ax.nodes["prompt"]!.text == "question")
    }

    @Test func anUnloadedWindowOrComposerReturnsANilSnapshotSoReadinessCanBePolled() throws {
        let ax = GeminiAXFixture()
        ax.focused = nil
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(try session.read().text == nil)
        ax.focused = "window"
        ax.nodes["window"]!.children = ["temporary"]
        #expect(try session.read().text == nil)
        ax.nodes["window"]!.children.append("prompt")
        #expect(try session.read().text == "")
    }

    @Test func escapeCancellationPreventsWritingAndSending() throws {
        let ax = GeminiAXFixture()
        var session = GeminiAXSession(ax: ax, pid: 42)
        ax.isCancelled = true
        #expect(throws: CancellationError.self) { try session.write("question") }
        #expect(ax.writes.isEmpty)
        ax.isCancelled = false
        try session.write("question")
        ax.isCancelled = true
        #expect(throws: CancellationError.self) { try session.submit() }
        #expect(ax.presses.isEmpty)
    }

    @Test func escapeDuringTraversalStopsBeforeReadingTheComposer() {
        let ax = GeminiAXFixture()
        ax.beforeMetadataRead = { ax.isCancelled = true }
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(throws: CancellationError.self) { try session.read() }
        #expect(ax.valueReads.isEmpty)
    }

    @Test func aSlowNodeCannotExtendInspectionWithoutAWallClockBound() {
        let ax = GeminiAXFixture()
        ax.beforeMetadataRead = {
            ax.beforeMetadataRead = nil
            Thread.sleep(forTimeInterval: 1.05)
        }
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(throws: Error.self) { try session.read() }
        #expect(ax.valueReads.isEmpty)
        #expect(ax.metadataReads.count == 1)
    }

    @Test func traversalStopsBeforeAnUnboundedTree() throws {
        let ax = GeminiAXFixture()
        ax.nodes["window"]!.children = (0..<500).map { "node\($0)" }
        for i in 0..<500 { ax.nodes["node\(i)"] = .init(role: "AXGroup") }
        var session = GeminiAXSession(ax: ax, pid: 42)
        #expect(throws: Error.self) { try session.read() }
        #expect(ax.metadataReads.count <= 250)
    }
}

private final class GeminiAXFixture: GeminiAccessibility {
    struct Node {
        var role: String
        var identifier = ""
        var description = ""
        var text = ""
        var children: [String] = []
        var enabled = true
    }
    var trusted = true
    var isCancelled = false
    var frontmostPID: Int32? = 42
    var focused: String? = "window"
    var nodes: [String: Node] = [
        "window": .init(role: "AXWindow", children: ["temporary", "prompt", "send"]),
        "temporary": .init(role: "AXButton", identifier: "tempChat_button"),
        "prompt": .init(role: "AXTextArea", description: "问问 Gemini"),
        "send": .init(role: "AXButton", identifier: "send_button")
    ]
    var valueReads: [String] = []
    var metadataReads: [String] = []
    var writes: [String] = []
    var presses: [String] = []
    var pressSucceeds = true
    var beforeTextRead: (() -> Void)?
    var beforeMetadataRead: (() -> Void)?
    func focusedWindow(pid: Int32) -> String? { focused }
    func metadata(_ element: String) -> GeminiAXMetadata {
        beforeMetadataRead?()
        metadataReads.append(element)
        let n = nodes[element]!
        return .init(role: n.role, identifier: n.identifier)
    }
    func children(_ element: String) -> [String] { nodes[element]?.children ?? [] }
    func promptDescription(_ element: String) -> String? { nodes[element]?.description }
    func text(_ element: String) -> String? { beforeTextRead?(); valueReads.append(element); return nodes[element]?.text }
    func isEnabled(_ element: String) -> Bool { nodes[element]?.enabled ?? false }
    func setText(_ text: String, of element: String) -> Bool {
        writes.append(element); nodes[element]!.text = text; return true
    }
    func press(_ element: String) -> Bool { presses.append(element); return pressSucceeds }
}
