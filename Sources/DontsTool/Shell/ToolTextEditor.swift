import AppKit
import DontsToolCore
import SwiftUI

struct EditorSelection: Equatable {
    let id = UUID()
    let range: NSRange
}

/// Native editing/undo/IME. Syntax decoration uses temporary layout attributes only.
struct ToolTextEditor: NSViewRepresentable {
    @Binding var text: String
    var readOnly = false
    var json = false
    var wrap = true
    var folding = false
    var selection: EditorSelection?
    var active = true
    var editRevision = 0
    var sharedUndoManager: UndoManager?
    var label = "文本编辑器"
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = !wrap
        scroll.borderType = .noBorder; scroll.drawsBackground = true
        scroll.backgroundColor = ToolTheme.editorNS
        let view = WorkspaceTextView(frame: scroll.bounds)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = !wrap
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = ToolTheme.inkNS; view.backgroundColor = ToolTheme.editorNS
        view.insertionPointColor = ToolTheme.accentNS
        view.onFocusChange = { context.coordinator.parent.onFocusChange($0) }
        view.isRichText = false; view.importsGraphics = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel(label)
        scroll.documentView = view
        let ruler = LineNumberRuler(textView: view)
        ruler.coordinator = context.coordinator
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        context.coordinator.textView = view
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.decorate() }
        }
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if !active, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        view.isHidden = !active
        // Hidden editors still need to apply native undo actions from the shared history.
        // Visibility and responder removal already prevent user input in the inactive mode.
        view.isEditable = !readOnly
        (view as? WorkspaceTextView)?.formatsWholeJSONPaste = folding
        scroll.hasHorizontalScroller = !wrap
        view.isHorizontallyResizable = !wrap
        view.textContainer?.widthTracksTextView = wrap
        view.textContainer?.containerSize = NSSize(width: wrap ? max(0, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if !view.string.utf16.elementsEqual(text.utf16), !view.hasMarkedText() {
            let selected = view.selectedRange(), origin = scroll.contentView.bounds.origin
            coordinator.updating = true
            let managedEdit = !coordinator.initialized || coordinator.editRevision != editRevision
            if managedEdit { view.breakUndoCoalescing(); view.undoManager?.disableUndoRegistration() }
            defer { if managedEdit { view.undoManager?.enableUndoRegistration() } }
            let range = NSRange(location: 0, length: (view.string as NSString).length)
            if readOnly {
                view.string = text
            } else if view.shouldChangeText(in: range, replacementString: text) {
                view.replaceCharacters(in: range, with: text)
                view.didChangeText()
            }
            view.setSelectedRange(NSRange(location: min(selected.location, view.string.utf16.count), length: 0))
            scroll.contentView.scroll(to: origin)
            coordinator.updating = false
        }
        coordinator.editRevision = editRevision
        coordinator.initialized = true
        if let selection, coordinator.selectionID != selection.id {
            coordinator.expandAll()
            coordinator.selectionID = selection.id
            let count = view.string.utf16.count
            let location = min(selection.range.location, count)
            let range = NSRange(location: location, length: min(selection.range.length, count - location))
            view.setSelectedRange(range); view.scrollRangeToVisible(range)
            // Selecting a diff must not steal keyboard focus from the difference list.
            view.showFindIndicator(for: range)
        }
        view.layoutManager?.delegate = folding ? coordinator : nil
        scroll.verticalRulerView?.ruleThickness = folding ? 54 : 46
        scroll.verticalRulerView?.toolTip = folding ? "点击箭头折叠或展开 JSON；同一行有多个容器时可选择目标" : nil
        coordinator.invalidateFoldsIfNeeded()
        coordinator.decorate()
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver { NotificationCenter.default.removeObserver(observer) }
        coordinator.decoration?.cancel()
        coordinator.cancelFoldScan()
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
        var parent: ToolTextEditor
        weak var textView: NSTextView?
        var updating = false
        var initialized = false
        var editRevision = 0
        var selectionID: UUID?
        var scrollObserver: NSObjectProtocol?
        var decoration: DispatchWorkItem?
        var foldModel = JSONFoldModel("")
        var foldScan: Task<JSONFoldModel, Never>?
        var foldScanSource: String?
        var foldScanRevision = 0
        func cancelFoldScan() {
            foldScanRevision += 1
            foldScan?.cancel()
            foldScan = nil
            foldScanSource = nil
        }
        func scheduleFoldScan() {
            guard let view = textView else { return }
            let source = parent.folding ? view.string : ""
            guard !foldModel.source.utf16.elementsEqual(source.utf16),
                  foldScanSource.map({ !$0.utf16.elementsEqual(source.utf16) }) ?? true else { return }
            cancelFoldScan()
            foldScanSource = source
            let revision = foldScanRevision
            let scan = Task.detached(priority: .userInitiated) { JSONFoldModel(source) }
            foldScan = scan
            Task { @MainActor [weak self] in
                let model = await scan.value
                guard let self, !scan.isCancelled, self.foldScanRevision == revision,
                      let view = self.textView, self.parent.folding,
                      view.string.utf16.elementsEqual(source.utf16) else { return }
                self.foldModel = model
                self.foldScan = nil
                self.foldScanSource = nil
                view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            }
        }
        var collapsed: Set<Int> = []
        func invalidateFoldsIfNeeded() {
            guard let view = textView else { return }
            let source = parent.folding ? view.string : ""
            let currentSource = foldScanSource ?? foldModel.source
            guard !currentSource.utf16.elementsEqual(source.utf16) else { return }
            cancelFoldScan()
            let hadFolds = !collapsed.isEmpty
            collapsed.removeAll()
            foldModel = JSONFoldModel("")
            if hadFolds {
                let range = NSRange(location: 0, length: view.string.utf16.count)
                view.layoutManager?.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
                view.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            }
        }
        func isHidden(_ index: Int) -> Bool {
            let location = foldModel.ranges[index].location
            return collapsed.contains { other in other != index && location > foldModel.ranges[other].location && location < NSMaxRange(foldModel.ranges[other]) - 1 }
        }
        func expandAll() {
            guard !collapsed.isEmpty, let view = textView else { return }
            collapsed.removeAll()
            let range = NSRange(location: 0, length: view.string.utf16.count)
            view.layoutManager?.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            view.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
        func toggleFold(_ index: Int) {
            guard let view = textView, foldModel.ranges.indices.contains(index) else { return }
            if collapsed.contains(index) { collapsed.remove(index) } else { collapsed.insert(index) }
            let range = foldModel.ranges[index]
            if view.selectedRange().location > range.location && view.selectedRange().location < NSMaxRange(range) - 1 { view.setSelectedRange(NSRange(location: range.location, length: 0)) }
            // Glyph and layout caches are independent; both must reflect the new visibility.
            view.layoutManager?.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            view.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            view.needsDisplay = true
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
        func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect rect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
            guard !collapsed.isEmpty, glyphRange.length > 0 else { return false }
            let first = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let last = layoutManager.characterIndexForGlyph(at: NSMaxRange(glyphRange) - 1)
            guard collapsed.contains(where: { index in let range = foldModel.ranges[index]; return first > range.location && last < NSMaxRange(range) - 1 }) else { return false }
            rect.pointee.size.height = 0; used.pointee.size.height = 0; baselineOffset.pointee = 0
            return true
        }
        func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
            guard !collapsed.isEmpty else { return 0 }
            var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
            var newProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            var changed = false
            for i in 0..<glyphRange.length {
                let position = characterIndexes[i]
                // Keep newline control glyphs so TextKit can lay out and collapse their line fragments.
                if collapsed.contains(where: { index in let range = foldModel.ranges[index]; return position > range.location && position < NSMaxRange(range) - 1 }) && !newProperties[i].contains(.controlCharacter) {
                    newGlyphs[i] = 0; newProperties[i] = .null; changed = true
                }
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(&newGlyphs, properties: &newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            return glyphRange.length
        }
        init(_ parent: ToolTextEditor) { self.parent = parent }
        func undoManager(for view: NSTextView) -> UndoManager? { parent.sharedUndoManager }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            expandAll()
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, let textView else { return }
            parent.text = textView.string
            invalidateFoldsIfNeeded()
            decorate()
        }
        func decorate() {
            decoration?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyDecoration() }
            decoration = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        private func applyDecoration() {
            guard let view = textView, !view.hasMarkedText(), let layout = view.layoutManager else { return }
            scheduleFoldScan()
            if let ruler = view.enclosingScrollView?.verticalRulerView as? LineNumberRuler { ruler.updateLines(view.string) }
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            let count = view.string.utf16.count
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: count))
            guard parent.json, count > 0, let container = view.textContainer else { return }
            let glyphs = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
            let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let start = max(0, visible.location - 1024)
            let range = NSRange(location: start, length: min(count - start, min(visible.length + 2048, 32768)))
            let source = view.string as NSString
            let fragment = source.substring(with: range)
            let regex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
            for match in regex.matches(in: fragment, range: NSRange(location: 0, length: fragment.utf16.count)) {
                let token = (fragment as NSString).substring(with: match.range)
                let fullRange = NSRange(location: range.location + match.range.location, length: match.range.length)
                let suffixStart = NSMaxRange(fullRange)
                let suffixLength = min(8, max(0, count - suffixStart))
                let isKey = token.hasPrefix("\"") && source.substring(with: NSRange(location: suffixStart, length: suffixLength)).trimmingCharacters(in: .whitespaces).hasPrefix(":")
                let color: NSColor = isKey ? ToolTheme.keyNS : token.hasPrefix("\"") ? ToolTheme.stringNS : ToolTheme.numberNS
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: NSRange(location: range.location + match.range.location, length: match.range.length))
            }
        }
    }
}

final class WorkspaceTextView: NSTextView {
    var formatsWholeJSONPaste = false
    func pasteWholeJSONIfNeeded(from pasteboard: NSPasteboard) -> Bool {
        guard formatsWholeJSONPaste, isEditable, !hasMarkedText() else { return false }
        let documentRange = NSRange(location: 0, length: string.utf16.count)
        guard selectedRange() == documentRange || string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let pasted = pasteboard.string(forType: .string),
              let formatted = JSONPaste.formatted(pasted) else { return false }
        insertText(formatted, replacementRange: documentRange)
        return true
    }
    override func paste(_ sender: Any?) {
        if pasteWholeJSONIfNeeded(from: .general) { return }
        super.paste(sender)
    }
    override func pasteAsPlainText(_ sender: Any?) {
        if pasteWholeJSONIfNeeded(from: .general) { return }
        super.pasteAsPlainText(sender)
    }
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { DispatchQueue.main.async { [weak self] in self?.onFocusChange?(true) } }
        return became
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.onFocusChange?(false) } }
        return resigned
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil); return true
            case "v" where isEditable: pasteAsPlainText(nil); return true
            case "x" where isEditable: cut(nil); return true
            case "a": selectAll(nil); return true
            case "z" where isEditable:
                if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }; return true
            case "f":
                let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
                performTextFinderAction(item); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
private final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    weak var coordinator: ToolTextEditor.Coordinator?
    private var cachedText = ""
    private var lineIndex = TextLineIndex("")
    func updateLines(_ text: String) {
        guard !cachedText.utf16.elementsEqual(text.utf16) else { return }
        cachedText = text
        lineIndex = TextLineIndex(text)
    }
    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = 46; clientView = textView
    }
    required init(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer, let coordinator else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= ruleThickness - 18 else { return }
        let y = point.y + text.visibleRect.minY - text.textContainerInset.height
        layout.ensureLayout(for: container)
        guard y >= 0, y < layout.usedRect(for: container).maxY, layout.numberOfGlyphs > 0 else { return }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        let line = lineIndex.lineNumber(atUTF16Offset: layout.characterIndexForGlyph(at: glyph))
        let candidates = (coordinator.foldModel.byLine[line] ?? []).filter { !coordinator.isHidden($0) }
        if candidates.count == 1 { coordinator.toggleFold(candidates[0]); return }
        guard !candidates.isEmpty else { return }
        let menu = NSMenu()
        for index in candidates {
            let range = coordinator.foldModel.ranges[index]
            let snippet = (coordinator.foldModel.source as NSString).substring(with: NSRange(location: range.location, length: min(range.length, 35))).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let item = NSMenuItem(title: (coordinator.collapsed.contains(index) ? "展开 " : "折叠 ") + snippet, action: #selector(toggleMenuItem(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func toggleMenuItem(_ item: NSMenuItem) { coordinator?.toggleFold(item.tag) }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        ToolTheme.gutterNS.setFill(); bounds.fill()
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let source = text.string as NSString
        let glyphRange = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        var previousLine = -1
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { [self] _, used, _, glyphs, _ in
            guard used.height > 0 else { return }
            let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let line = lineIndex.lineNumber(atUTF16Offset: min(chars.location, source.length))
            guard line != previousLine else { return }
            previousLine = line
            let y = used.minY + text.textContainerInset.height - text.visibleRect.minY
            let label = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ToolTheme.secondaryNS]
            let inset: CGFloat = coordinator?.parent.folding == true ? 18 : 10
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - inset, y: y), withAttributes: attributes)
            if let coordinator {
                let candidates = (coordinator.foldModel.byLine[line] ?? []).filter { !coordinator.isHidden($0) }
                if !candidates.isEmpty {
                    let icon = (candidates.contains(where: { coordinator.collapsed.contains($0) }) ? "▸" : "▾") as NSString
                    icon.draw(at: NSPoint(x: ruleThickness - 14, y: y), withAttributes: attributes)
                }
            }
        }
    }
}

struct JSONFoldModel: Sendable {
    let source: String
    let ranges: [NSRange]
    let byLine: [Int: [Int]]
    init(_ source: String) {
        self.source = source
        guard let document = try? JSONDocument.parse(source) else { ranges = []; byLine = [:]; return }
        var found: [NSRange] = [], pending = [document.root]
        while let node = pending.popLast() {
            switch node.value {
            case .object(let members) where !members.isEmpty:
                found.append(node.range); pending.append(contentsOf: members.reversed().map(\.value))
            case .array(let items) where !items.isEmpty:
                found.append(node.range); pending.append(contentsOf: items.reversed())
            default: break
            }
        }
        ranges = found
        let lines = TextLineIndex(source)
        var index: [Int: [Int]] = [:]
        for (i, range) in found.enumerated() { index[lines.lineNumber(atUTF16Offset: range.location), default: []].append(i) }
        byLine = index
    }
}

enum JSONPaste {
    static func formatted(_ pasted: String) -> String? {
        let source = fencedJSON(in: pasted) ?? pasted
        return try? JSONDocument.parse(source).formatted(pretty: true)
    }

    private static func fencedJSON(in pasted: String) -> String? {
        let block = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard block.hasPrefix("```"), block.hasSuffix("```"),
              let firstBreak = block.firstIndex(where: \.isNewline),
              let lastBreak = block.lastIndex(where: \.isNewline), firstBreak < lastBreak else { return nil }
        let opening = block[..<firstBreak].trimmingCharacters(in: .whitespaces).lowercased()
        let closing = block[block.index(after: lastBreak)...].trimmingCharacters(in: .whitespaces)
        guard (opening == "```json" || opening == "```"), closing == "```" else { return nil }
        return String(block[block.index(after: firstBreak)..<lastBreak])
    }
}
