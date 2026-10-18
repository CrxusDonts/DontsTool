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
            coordinator.selectionID = selection.id
            let count = view.string.utf16.count
            let location = min(selection.range.location, count)
            let range = NSRange(location: location, length: min(selection.range.length, count - location))
            view.setSelectedRange(range); view.scrollRangeToVisible(range)
            // Selecting a diff must not steal keyboard focus from the difference list.
            view.showFindIndicator(for: range)
        }
        coordinator.decorate()
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver { NotificationCenter.default.removeObserver(observer) }
        coordinator.decoration?.cancel()
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ToolTextEditor
        weak var textView: NSTextView?
        var updating = false
        var initialized = false
        var editRevision = 0
        var selectionID: UUID?
        var scrollObserver: NSObjectProtocol?
        var decoration: DispatchWorkItem?
        init(_ parent: ToolTextEditor) { self.parent = parent }
        func undoManager(for view: NSTextView) -> UndoManager? { parent.sharedUndoManager }
        func textDidChange(_ notification: Notification) {
            guard !updating, let textView else { return }
            parent.text = textView.string
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

private final class WorkspaceTextView: NSTextView {
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
    override func drawHashMarksAndLabels(in rect: NSRect) {
        ToolTheme.gutterNS.setFill(); bounds.fill()
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let source = text.string as NSString
        let glyphRange = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        var previousLine = -1
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { [self] _, used, _, glyphs, _ in
            let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let line = lineIndex.lineNumber(atUTF16Offset: min(chars.location, source.length))
            guard line != previousLine else { return }
            previousLine = line
            let y = used.minY + text.textContainerInset.height - text.visibleRect.minY
            let label = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ToolTheme.secondaryNS]
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 10, y: y), withAttributes: attributes)
        }
    }
}
