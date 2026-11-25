import Combine
import Foundation

/// Shares one undo history with the document's native text editors.
@MainActor
public final class ToolDraftEditor: ObservableObject {
    public let document: ToolDocument
    public let undoManager: UndoManager
    @Published public private(set) var revision = 0

    public init(document: ToolDocument) {
        self.document = document
        undoManager = UndoManager()
    }

    public func run() {
        let session = document.session
        guard session.editsTextInPlace else { session.run(); return }
        let actionName = session.primaryTitle
        session.run(committingText: { [weak self] text in
            self?.replaceInput(text, actionName: actionName)
        })
    }

    /// A result-to-input operation restores its previous direction along with the text.
    public func replaceInput(_ text: String, mode: String? = nil, actionName: String = "替换输入") {
        let oldInput = document.session.input
        let oldMode = document.session.mode
        let nextMode = mode ?? oldMode
        guard !sameBytes(text, oldInput) || !sameBytes(nextMode, oldMode) else { return }
        registerUndo(named: actionName) { editor in
            editor.replaceInput(oldInput, mode: oldMode, actionName: actionName)
        }
        document.session.input = text
        document.session.mode = nextMode
        revision &+= 1
    }

    public func replaceComparisonSide(_ text: String, right: Bool) {
        applyComparisonSide(text, right: right, comparing: true)
    }
    private func applyComparisonSide(_ text: String, right: Bool, comparing: Bool) {
        let previous = right ? document.session.compareRight : document.session.compareLeft
        let previousMode = document.session.comparing
        guard !sameBytes(text, previous) || comparing != previousMode else { return }
        registerUndo(named: "替换对比内容") { editor in
            editor.applyComparisonSide(previous, right: right, comparing: previousMode)
        }
        if right { document.session.compareRight = text } else { document.session.compareLeft = text }
        document.session.comparing = comparing
        revision &+= 1
    }

    public func swapComparison() {
        applyComparison(ComparisonDraft(
            left: document.session.compareRight, right: document.session.compareLeft,
            leftTitle: document.rightTitle, rightTitle: document.leftTitle
        ))
    }

    @discardableResult
    public func formatComparisonBoth() throws -> Bool {
        let left = document.session.compareLeft
        let right = document.session.compareRight

        let formattedLeft: String
        if left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            formattedLeft = left
        } else {
            do {
                formattedLeft = try JSONDocument.parse(left).formatted(pretty: true)
            } catch {
                let sideError = JSONSideIssue(side: "左侧", underlying: error)
                document.session.presentError(sideError)
                throw sideError
            }
        }

        let formattedRight: String
        if right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            formattedRight = right
        } else {
            do {
                formattedRight = try JSONDocument.parse(right).formatted(pretty: true)
            } catch {
                let sideError = JSONSideIssue(side: "右侧", underlying: error)
                document.session.presentError(sideError)
                throw sideError
            }
        }

        let changed = !sameBytes(formattedLeft, left) || !sameBytes(formattedRight, right)
        applyComparison(
            ComparisonDraft(
                left: formattedLeft,
                right: formattedRight,
                leftTitle: document.leftTitle,
                rightTitle: document.rightTitle
            ),
            actionName: "格式化两侧"
        )
        return changed
    }

    private struct ComparisonDraft: Sendable {
        let left, right, leftTitle, rightTitle: String
    }

    private func applyComparison(_ next: ComparisonDraft, actionName: String = "交换对比两侧") {
        let previous = ComparisonDraft(
            left: document.session.compareLeft, right: document.session.compareRight,
            leftTitle: document.leftTitle, rightTitle: document.rightTitle
        )
        guard !sameBytes(next.left, previous.left) || !sameBytes(next.right, previous.right)
            || !sameBytes(next.leftTitle, previous.leftTitle) || !sameBytes(next.rightTitle, previous.rightTitle)
        else { return }
        registerUndo(named: actionName) { editor in editor.applyComparison(previous, actionName: actionName) }
        document.session.compareLeft = next.left
        document.session.compareRight = next.right
        document.leftTitle = next.leftTitle
        document.rightTitle = next.rightTitle
        revision &+= 1
    }

    private func sameBytes(_ first: String, _ second: String) -> Bool {
        first.utf8.elementsEqual(second.utf8)
    }

    private func registerUndo(named name: String, action: @escaping @MainActor @Sendable (ToolDraftEditor) -> Void) {
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { action(editor) }
        }
        undoManager.setActionName(name)
    }
}
