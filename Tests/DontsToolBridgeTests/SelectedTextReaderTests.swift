import ApplicationServices
import Testing

@Suite("Accessibility selection reading")
struct SelectedTextReaderTests {
    @Test func emptyFocusedSelectionStillTriesHitAndAncestors() {
        var ax = SelectionAXFixture()
        ax.text["focus"] = ""
        ax.text["hit"] = ""
        ax.parents["hit"] = "web"
        ax.parents["web"] = "window"
        ax.text["web"] = "selected browser text"
        #expect(SelectionTextExtraction.read(ax, pid: 42, at: .zero).text == "selected browser text")
    }

    @Test func missingWindowAttributeUsesWindowAncestor() {
        var ax = SelectionAXFixture()
        ax.windows = [:]
        ax.parents["hit"] = "web"
        ax.parents["web"] = "window"
        ax.parents["focus"] = "web"
        ax.text["web"] = "selection"
        #expect(SelectionTextExtraction.read(ax, pid: 42, at: .zero).text == "selection")
    }

    @Test func refusesSelectionFromAnotherWindow() {
        var ax = SelectionAXFixture()
        ax.windows["hit"] = "other-window"
        ax.text["focus"] = "private other document"
        #expect(SelectionTextExtraction.read(ax, pid: 42, at: .zero).text == nil)
    }

    @Test func secureFocusedOrHitElementPreventsAncestorRead() {
        for secure in ["focus", "hit", "web"] {
            var ax = SelectionAXFixture()
            ax.parents["hit"] = "web"
            ax.parents["web"] = "window"
            ax.secure.insert(secure)
            ax.text["web"] = "must not read"
            ax.text["focus"] = "must not read"
            #expect(SelectionTextExtraction.read(ax, pid: 42, at: .zero).text == nil)
        }
    }

    @Test func noPermissionHasExplicitFailureAndDoesNotReadElements() {
        var ax = SelectionAXFixture()
        ax.trusted = false
        let reading = SelectionTextExtraction.read(ax, pid: 42, at: .zero)
        #expect(reading.text == nil)
        #expect(reading.diagnostic.contains("辅助功能"))
    }

    @Test func missingWindowEvidenceDoesNotReadOtherFocusedDocument() {
        var ax = SelectionAXFixture()
        ax.windows = [:]
        ax.parents = [:]
        ax.text["focus"] = "must not read"
        #expect(SelectionTextExtraction.read(ax, pid: 42, at: .zero).text == nil)
    }

    @Test func oversizedTextCannotFallThroughToAnotherCandidate() {
        var ax = SelectionAXFixture()
        ax.text["hit"] = String(repeating: "a", count: 8001)
        ax.text["focus"] = "unrelated"
        #expect(SelectionTextExtraction.read(ax, pid: 42, at: .zero).text == nil)
    }
}

private struct SelectionAXFixture: SelectionAccessibility {
    typealias Element = String
    var trusted = true
    var windows = ["focus": "window", "hit": "window", "web": "window"]
    var parents = ["focus": "window", "hit": "window"]
    var text: [String: String] = [:]
    var secure = Set<String>()
    func application(_ pid: pid_t) -> String { "app" }
    func focusedElement(in app: String) -> String? { "focus" }
    func focusedWindow(in app: String) -> String? { "window" }
    func element(at point: CGPoint, in app: String) -> String? { "hit" }
    func window(of element: String) -> String? { windows[element] }
    func parent(of element: String) -> String? { parents[element] }
    func isWindow(_ element: String) -> Bool { element == "window" || element == "other-window" }
    func isSecure(_ element: String) -> Bool { secure.contains(element) }
    func selectedText(of element: String) -> String? { text[element] }
}
