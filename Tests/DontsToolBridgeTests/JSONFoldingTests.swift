import AppKit
import SwiftUI
import Testing
@testable import DontsToolCore

@Suite("JSON folding") @MainActor struct JSONFoldingTests {
    @Test func rangesAndSource() {
        let source = #"{"😀":[1,{"x":2}],"empty":{}}"#
        let model = JSONFoldModel(source)
        #expect(model.ranges.map { (source as NSString).substring(with: $0) } == [source, #"[1,{"x":2}]"#, #"{"x":2}"#])
        #expect(model.source == source)
        #expect(JSONFoldModel("{broken").ranges.isEmpty)
    }
    @Test(arguments: ["\n", "\r\n"])
    func actualLayout(_ newline: String) {
        let source = (["{", "  \"a\": [", "    1,", "    2,", "    3,", "    4", "  ]", "}"]).joined(separator: newline)
        let storage = NSTextStorage(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        let layout = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 500, height: 10000))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 10000), textContainer: container)
        let coordinator = ToolTextEditor.Coordinator(ToolTextEditor(text: .constant(source), json: true, folding: true))
        coordinator.textView = view; layout.delegate = coordinator; coordinator.foldModel = JSONFoldModel(source)
        layout.ensureLayout(for: container); let expanded = layout.usedRect(for: container).height
        coordinator.toggleFold(0); layout.ensureLayout(for: container)
        let folded = layout.usedRect(for: container).height
        #expect(folded < expanded / 2)
        #expect(view.string == source)
        coordinator.toggleFold(0); layout.ensureLayout(for: container)
        #expect(layout.usedRect(for: container).height == expanded)
    }
    @Test func copyAndEditPreserveSource() {
        let source = "{\n  \"a\": [1, 2]\n}"
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        view.string = source
        let undoManager = UndoManager()
        let coordinator = ToolTextEditor.Coordinator(ToolTextEditor(text: .constant(source), json: true, folding: true, sharedUndoManager: undoManager))
        coordinator.textView = view; view.delegate = coordinator; view.layoutManager?.delegate = coordinator
        coordinator.foldModel = JSONFoldModel(source); coordinator.toggleFold(0)
        #expect(!undoManager.canUndo)
        view.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("JSONFoldingTests.\(UUID())"))
        #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == source)
        pasteboard.releaseGlobally()
        #expect(view.string == source)
        #expect(view.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: " "))
        #expect(coordinator.collapsed.isEmpty)
        #expect(view.string == source)
    }
    @Test func staleBackgroundScanCannotReplaceNewSource() async throws {
        let old = "[" + Array(repeating: "{\"value\":1}", count: 20_000).joined(separator: ",") + "]"
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        view.string = old
        let coordinator = ToolTextEditor.Coordinator(ToolTextEditor(text: .constant(old), json: true, folding: true))
        coordinator.textView = view
        coordinator.scheduleFoldScan()
        view.string = #"{"new":[1]}"#
        coordinator.invalidateFoldsIfNeeded()
        coordinator.scheduleFoldScan()
        for _ in 0..<100 where coordinator.foldScan != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(coordinator.foldModel.source == view.string)
        #expect(coordinator.foldModel.ranges.count == 2)
    }
    @Test func pasteFormattingPreservesInvalidInput() {
        #expect(JSONPaste.formatted("{invalid") == "{invalid")
    }
    @Test func nativeWholePasteIsOneUndo() {
        let manager = UndoManager()
        let view = WorkspaceTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let coordinator = ToolTextEditor.Coordinator(ToolTextEditor(text: .constant(""), folding: true, sharedUndoManager: manager))
        view.delegate = coordinator; coordinator.textView = view
        view.allowsUndo = true; view.formatsWholeJSONPaste = true
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(#"{"x":[1,2]}"#, forType: .string)
        #expect(view.pasteWholeJSONIfNeeded(from: pasteboard))
        #expect(view.string == "{\n  \"x\": [\n    1,\n    2\n  ]\n}")
        manager.undo()
        #expect(view.string == "")
        manager.redo()
        #expect(view.string.contains("\n"))
        view.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!view.pasteWholeJSONIfNeeded(from: pasteboard))
    }
}
