import Foundation
import Testing
@testable import DontsToolCore

@Suite("原地工具操作") @MainActor
struct ToolInPlaceEditingTests {
    @Test func formattingUpdatesDocumentAndUndoRestoresOriginal() async {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .json, input: "{\"id\":9007199254740993}"))
        let editor = ToolDraftEditor(document: document)
        editor.run()
        await waitUntil { document.session.input.contains("\n") }
        #expect(document.session.input == "{\n  \"id\": 9007199254740993\n}")
        #expect(document.session.isFresh)
        #expect(document.session.status == "格式化完成")
        editor.undoManager.undo()
        #expect(document.session.input == "{\"id\":9007199254740993}")
        editor.undoManager.redo()
        #expect(document.session.input == "{\n  \"id\": 9007199254740993\n}")
    }

    @Test func encodingAndDecodingOperateOnCurrentTextWithoutChangingDirection() async {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .base64, input: "hello"))
        let editor = ToolDraftEditor(document: document)
        editor.run()
        await waitUntil { document.session.input == "aGVsbG8=" }
        #expect(document.session.mode == "encode")
        while editor.undoManager.groupingLevel > 0 { try? await Task.sleep(for: .milliseconds(1)) }
        document.session.mode = "decode"
        editor.run()
        await waitUntil { document.session.input == "hello" }
        #expect(document.session.mode == "decode")
        editor.undoManager.undo()
        #expect(document.session.input == "aGVsbG8=")
        #expect(document.session.mode == "decode")
    }

    @Test func URLTransformationPreservesPeerDraftAndRemainsUndoable() async {
        let store = ToolDocumentStore()
        let document = store.create(ToolOpenRequest(kind: .url, input: "a+b c"))
        let peer = store.create(ToolOpenRequest(kind: .url, input: "peer"))
        let editor = ToolDraftEditor(document: document)
        editor.run()
        await waitUntil { document.session.input == "a%2Bb%20c" }
        #expect(peer.session.input == "peer")
        editor.undoManager.undo()
        #expect(document.session.input == "a+b c")
    }

    @Test func invalidConversionKeepsTextAndAddsNoUndoCommand() async {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .base64, mode: "decode", input: "%%%"))
        let editor = ToolDraftEditor(document: document)
        editor.run()
        await waitUntil { document.session.errorMessage != nil }
        #expect(document.session.input == "%%%")
        #expect(!editor.undoManager.canUndo)
    }

    @Test func comparisonAndHashKeepSourceText() async {
        let store = ToolDocumentStore()
        let json = store.create(ToolOpenRequest(kind: .json, input: "editing draft"))
        json.session.comparing = true
        json.session.compareLeft = "1"
        json.session.compareRight = "2"
        let jsonEditor = ToolDraftEditor(document: json)
        jsonEditor.run()
        await waitUntil { json.session.comparison != nil }
        #expect(json.session.comparison?.modified == 1)
        #expect(json.session.input == "editing draft")
        #expect(json.session.compareLeft == "1" && json.session.compareRight == "2")
        let hash = store.create(ToolOpenRequest(kind: .hash, input: "hello"))
        let hashEditor = ToolDraftEditor(document: hash)
        hashEditor.run()
        await waitUntil { hash.session.isFresh }
        #expect(hash.session.input == "hello")
        #expect(hash.session.output == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(!hashEditor.undoManager.canUndo)
    }

    @Test func oversizedEncodedResultCannotStrandTheEditableDocument() async {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .base64, input: String(repeating: "a", count: 1_600_000)))
        let editor = ToolDraftEditor(document: document)
        editor.run()
        await waitUntil { document.session.errorMessage != nil || document.session.isFresh }
        #expect(document.session.errorMessage != nil)
        let retainedByteCount = document.session.input.utf8.count
        let retainedOriginalCharacters = document.session.input.utf8.allSatisfy { $0 == 97 }
        let outputByteCount = document.session.output.utf8.count
        #expect(retainedByteCount == 1_600_000)
        #expect(retainedOriginalCharacters)
        #expect(outputByteCount == 0)
        #expect(!editor.undoManager.canUndo)
    }

    @Test func cancellingQueuedTransformationCannotReplaceNewDraft() async {
        let document = ToolDocumentStore().create(ToolOpenRequest(kind: .base64, input: "hello"))
        let editor = ToolDraftEditor(document: document)
        editor.run()
        document.session.input = "new draft"
        for _ in 0..<20 { await Task.yield() }
        #expect(document.session.input == "new draft")
        #expect(document.session.output.isEmpty)
        #expect(!editor.undoManager.canUndo)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !predicate(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(predicate(), "转换应在等待上限内完成")
    }
}
