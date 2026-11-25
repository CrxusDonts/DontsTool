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
        #expect(JSONPaste.formatted("{invalid") == nil)
        let fenced = "```json\n{invalid\n```"
        #expect(JSONPaste.formatted(fenced) == nil)
    }
    @Test(arguments: ["", " \n\t"], [false, true])
    func nativeWholePasteIsOneUndo(_ previous: String, _ fenced: Bool) throws {
        let sample = #"{"project":"DontsTool","settings":{"theme":"dark","editor":{"autoFormat":true,"tabSize":2}},"tools":[{"name":"JSON","actions":["格式化","压缩","折叠"]},{"name":"便笺","actions":["新建","搜索"]}],"tags":["macOS","效率工具"],"archived":false}"#
        let expected = try JSONDocument.parse(sample).formatted(pretty: true)
        let manager = UndoManager()
        let view = WorkspaceTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        view.string = previous
        view.setSelectedRange(NSRange(location: previous.utf16.count, length: 0))
        let coordinator = ToolTextEditor.Coordinator(ToolTextEditor(text: .constant(previous), folding: true, sharedUndoManager: manager))
        view.delegate = coordinator; coordinator.textView = view
        view.allowsUndo = true; view.formatsWholeJSONPaste = true
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(fenced ? "```json\r\n" + sample + "\r\n```" : sample, forType: .string)
        #expect(view.pasteWholeJSONIfNeeded(from: pasteboard))
        #expect(view.string == expected)
        manager.undo()
        #expect(view.string == previous)
        manager.redo()
        #expect(view.string == expected)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!view.pasteWholeJSONIfNeeded(from: pasteboard))
    }

    @Test func foldModelMetadataAndDepthCommandsWorkCleanly() {
        let source = """
        {
          "app": "DontsTool",
          "settings": {
            "editor": {
              "tabSize": 2
            }
          }
        }
        """
        let model = JSONFoldModel(source)
        #expect(model.depths == [0, 1, 2])
        #expect(model.lineSpans == [8, 5, 3])
        #expect(model.summaries == ["2 键 · 8 行", "1 键 · 5 行", "1 键 · 3 行"])

        let storage = NSTextStorage(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 500, height: 10000))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = WorkspaceTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 10000), textContainer: container)
        let coordinator = ToolTextEditor.Coordinator(ToolTextEditor(text: .constant(source), json: true, folding: true))
        coordinator.textView = view
        layout.delegate = coordinator
        coordinator.foldModel = model

        coordinator.applyFoldCommand(.collapseToDepth(1))
        #expect(coordinator.collapsed == Set([1, 2]))

        coordinator.applyFoldCommand(.collapseToDepth(2))
        #expect(coordinator.collapsed == Set([2]))

        coordinator.applyFoldCommand(.expandAll)
        #expect(coordinator.collapsed.isEmpty)

        let host = NSHostingView(rootView: ToolTextEditor(text: .constant(source), json: true, folding: true))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        host.layoutSubtreeIfNeeded()
        func findScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScrollView).first
        }
        #expect(findScrollView(in: host)?.verticalRulerView?.ruleThickness == 70)
    }

    @Test func keyEquivalentsOnlyTargetFocusedWorkspaceTextView() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        window.contentView = content

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let left = WorkspaceTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        left.isEditable = true
        left.formatsWholeJSONPaste = true
        left.pasteboardForPaste = { pasteboard }

        let right = WorkspaceTextView(frame: NSRect(x: 210, y: 0, width: 200, height: 200))
        right.isEditable = true
        right.formatsWholeJSONPaste = true
        right.pasteboardForPaste = { pasteboard }

        let field = NSTextField(frame: NSRect(x: 420, y: 0, width: 160, height: 24))

        content.addSubview(left)
        content.addSubview(right)
        content.addSubview(field)

        let cmdV = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            )
        )

        pasteboard.clearContents()
        pasteboard.setString(#"{"side":"right"}"#, forType: .string)
        #expect(window.makeFirstResponder(right))
        #expect(window.performKeyEquivalent(with: cmdV))
        #expect(left.string.isEmpty)
        #expect(right.string == "{\n  \"side\": \"right\"\n}")

        pasteboard.clearContents()
        pasteboard.setString(#"{"side":"left"}"#, forType: .string)
        #expect(window.makeFirstResponder(left))
        #expect(window.performKeyEquivalent(with: cmdV))
        #expect(left.string == "{\n  \"side\": \"left\"\n}")
        #expect(right.string == "{\n  \"side\": \"right\"\n}")

        pasteboard.clearContents()
        pasteboard.setString(#"{"side":"field"}"#, forType: .string)
        #expect(window.makeFirstResponder(field))
        #expect(!left.performKeyEquivalent(with: cmdV))
        #expect(!right.performKeyEquivalent(with: cmdV))
        #expect(left.string == "{\n  \"side\": \"left\"\n}")
        #expect(right.string == "{\n  \"side\": \"right\"\n}")
    }
}
