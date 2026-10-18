import Foundation
import Testing
@testable import DontsToolCore

@Suite("工具草稿撤销") @MainActor
struct ToolDraftEditorTests {
    @Test func transferringIntoHiddenComparisonSideRestoresPreviousDraft() {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .json, input: "true"))
        document.session.compareRight = "valuable old draft"
        let editor = ToolDraftEditor(document: document)
        editor.replaceComparisonSide("new result", right: true)
        #expect(document.session.comparing)
        #expect(document.session.compareRight == "new result")
        editor.undoManager.undo()
        #expect(!document.session.comparing)
        #expect(document.session.compareRight == "valuable old draft")
        editor.undoManager.redo()
        #expect(document.session.comparing)
        #expect(document.session.compareRight == "new result")
    }
    @Test func inputAndModeUndoAndRedoAsOneCommand() {
        let store = ToolDocumentStore()
        let document = store.create(ToolOpenRequest(kind: .base64, mode: "encode", input: "hello"))
        document.session.urlSafe = true
        let editor = ToolDraftEditor(document: document)
        editor.replaceInput("aGVsbG8=", mode: "decode")
        #expect(document.session.input == "aGVsbG8=")
        #expect(document.session.mode == "decode")
        #expect(editor.revision == 1)
        document.session.urlSafe = false
        editor.undoManager.undo()
        #expect(document.session.input == "hello")
        #expect(document.session.mode == "encode")
        #expect(!document.session.urlSafe)
        #expect(editor.revision == 2)
        #expect(!editor.undoManager.canUndo)
        #expect(editor.undoManager.canRedo)
        editor.undoManager.redo()
        #expect(document.session.input == "aGVsbG8=")
        #expect(document.session.mode == "decode")
        #expect(editor.revision == 3)
        #expect(!document.session.urlSafe)
    }

    @Test func comparisonTextAndNamesSwapAndRestoreTogether() {
        let store = ToolDocumentStore()
        let document = store.create(ToolOpenRequest(kind: .json, input: "edit draft"))
        document.session.compareLeft = "{\"left\":1}"
        document.session.compareRight = "{\"right\":2}"
        document.leftTitle = "生产"
        document.rightTitle = "预期"
        let editor = ToolDraftEditor(document: document)
        editor.swapComparison()
        #expect(document.session.compareLeft == "{\"right\":2}")
        #expect(document.session.compareRight == "{\"left\":1}")
        #expect(document.leftTitle == "预期")
        #expect(document.rightTitle == "生产")
        #expect(editor.revision == 1)
        editor.undoManager.undo()
        #expect(document.session.compareLeft == "{\"left\":1}")
        #expect(document.session.compareRight == "{\"right\":2}")
        #expect(document.leftTitle == "生产")
        #expect(document.rightTitle == "预期")
        #expect(editor.revision == 2)
        #expect(!editor.undoManager.canUndo)
        editor.undoManager.redo()
        #expect(document.session.compareLeft == "{\"right\":2}")
        #expect(document.session.compareRight == "{\"left\":1}")
        #expect(document.leftTitle == "预期")
        #expect(document.rightTitle == "生产")
        #expect(editor.revision == 3)
        #expect(document.session.input == "edit draft")
    }

    @Test func peerDocumentsHaveIndependentUndoStacks() {
        let store = ToolDocumentStore()
        let first = store.create(ToolOpenRequest(kind: .base64, input: "first"))
        let second = store.create(ToolOpenRequest(kind: .base64, input: "second"))
        let firstEditor = ToolDraftEditor(document: first)
        let secondEditor = ToolDraftEditor(document: second)
        firstEditor.replaceInput("first replacement")
        secondEditor.replaceInput("second replacement", mode: "decode")
        firstEditor.undoManager.undo()
        #expect(first.session.input == "first")
        #expect(second.session.input == "second replacement")
        #expect(second.session.mode == "decode")
        #expect(secondEditor.undoManager.canUndo)
        secondEditor.undoManager.undo()
        #expect(second.session.input == "second")
        #expect(second.session.mode == "encode")
        #expect(firstEditor.undoManager.canRedo)
    }

    @Test func commandsInSeparateEventsKeepSeparateUndoGroups() async {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .base64, input: "first"))
        let editor = ToolDraftEditor(document: document)
        editor.replaceInput("second")
        while editor.undoManager.groupingLevel > 0 { try? await Task.sleep(for: .milliseconds(1)) }
        editor.replaceInput("third")
        editor.undoManager.undo()
        #expect(document.session.input == "second")
        editor.undoManager.undo()
        #expect(document.session.input == "first")
        editor.undoManager.redo()
        #expect(document.session.input == "second")
        editor.undoManager.redo()
        #expect(document.session.input == "third")
    }

    @Test func compoundCommandKeepsEarlierNativeEditFromPreviousEventAsSeparateUndo() async {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .base64, input: "hello"))
        let editor = ToolDraftEditor(document: document)
        editor.undoManager.registerUndo(withTarget: document.session) { session in
            MainActor.assumeIsolated { session.input = "hello" }
        }
        document.session.input = "hello!"
        while editor.undoManager.groupingLevel > 0 { try? await Task.sleep(for: .milliseconds(1)) }
        editor.replaceInput("aGVsbG8h", mode: "decode")
        #expect(editor.undoManager.groupsByEvent)
        editor.undoManager.undo()
        #expect(document.session.input == "hello!")
        #expect(document.session.mode == "encode")
        editor.undoManager.undo()
        #expect(document.session.input == "hello")
    }

    @Test func unchangedCommandsDoNotCreateUndoOrRevision() {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .json, input: "same"))
        document.session.compareLeft = "same"
        document.session.compareRight = "same"
        document.leftTitle = "same"
        document.rightTitle = "same"
        let editor = ToolDraftEditor(document: document)
        editor.replaceInput("same")
        editor.replaceInput("same", mode: "format")
        editor.swapComparison()
        #expect(editor.revision == 0)
        #expect(!editor.undoManager.canUndo)
    }

    @Test func modeOnlyChangeRemainsUndoable() {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .base64, input: "same"))
        let editor = ToolDraftEditor(document: document)
        editor.replaceInput("same", mode: "decode")
        editor.undoManager.undo()
        #expect(document.session.input == "same")
        #expect(document.session.mode == "encode")
        #expect(editor.revision == 2)
    }

    @Test func canonicallyEquivalentTextStillCreatesUndoForDifferentBytes() {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .base64, input: "é"))
        let editor = ToolDraftEditor(document: document)
        editor.replaceInput("e\u{301}")
        #expect(Array(document.session.input.utf8) == [101, 204, 129])
        #expect(editor.revision == 1)
        editor.undoManager.undo()
        #expect(Array(document.session.input.utf8) == [195, 169])
        editor.undoManager.redo()
        #expect(Array(document.session.input.utf8) == [101, 204, 129])
    }
}
