import AppKit
import DontsToolCore
import SwiftUI

struct EditorSelection: Equatable {
    let id = UUID()
    let range: NSRange
}

struct EditorFoldCommand: Equatable {
    enum Action: Equatable {
        case collapseAll
        case expandAll
        case collapseToDepth(Int)
    }

    let id = UUID()
    let action: Action
}

struct EditorCursorPosition: Equatable {
    let line: Int
    let column: Int
    let utf16Offset: Int
}

/// Native editing/undo/IME. Syntax decoration uses temporary layout attributes only.
struct ToolTextEditor: NSViewRepresentable {
    @Binding var text: String
    var readOnly = false
    var json = false
    var wrap = true
    var folding = false
    var selection: EditorSelection?
    var foldCommand: EditorFoldCommand? = nil
    var diffLineKinds: [Int: JSONDifference.Kind] = [:]
    var active = true
    var editRevision = 0
    var sharedUndoManager: UndoManager?
    var label = "文本编辑器"
    var onFocusChange: (Bool) -> Void = { _ in }
    var onCursorChange: ((EditorCursorPosition) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !wrap
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = ToolTheme.editorNS

        let view = WorkspaceTextView(frame: scroll.bounds)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = !wrap
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 14, height: 12)

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        view.font = font
        view.defaultParagraphStyle = paragraphStyle
        view.typingAttributes = [
            .font: font,
            .foregroundColor: ToolTheme.inkNS,
            .paragraphStyle: paragraphStyle
        ]
        view.textColor = ToolTheme.inkNS
        view.backgroundColor = ToolTheme.editorNS
        view.insertionPointColor = ToolTheme.accentNS
        view.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]
        view.coordinator = context.coordinator
        view.onFocusChange = { context.coordinator.parent.onFocusChange($0) }
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel(label)
        scroll.documentView = view

        let ruler = LineNumberRuler(textView: view)
        ruler.coordinator = context.coordinator
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.textView = view

        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.decorate() }
        }

        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }

        if !active, view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
        view.isHidden = !active
        // Hidden editors still need to apply native undo actions from the shared history.
        // Visibility and responder removal already prevent user input in the inactive mode.
        view.isEditable = !readOnly

        if let workspaceView = view as? WorkspaceTextView {
            workspaceView.formatsWholeJSONPaste = folding
            workspaceView.showIndentGuides = json
            let diffChanged = workspaceView.diffLineKinds != diffLineKinds
            workspaceView.diffLineKinds = diffLineKinds
            if diffChanged {
                workspaceView.needsDisplay = true
            }
        }

        scroll.hasHorizontalScroller = !wrap
        view.isHorizontallyResizable = !wrap
        view.textContainer?.widthTracksTextView = wrap
        view.textContainer?.containerSize = NSSize(
            width: wrap ? max(0, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        if !view.string.utf16.elementsEqual(text.utf16), !view.hasMarkedText() {
            let selected = view.selectedRange()
            let origin = scroll.contentView.bounds.origin
            coordinator.updating = true
            let managedEdit = !coordinator.initialized || coordinator.editRevision != editRevision
            if managedEdit {
                view.breakUndoCoalescing()
                view.undoManager?.disableUndoRegistration()
            }
            defer {
                if managedEdit {
                    view.undoManager?.enableUndoRegistration()
                }
            }
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
            view.setSelectedRange(range)
            view.scrollRangeToVisible(range)
            // Selecting a diff must not steal keyboard focus from the difference list.
            view.showFindIndicator(for: range)
        }

        view.layoutManager?.delegate = folding ? coordinator : nil
        if let ruler = scroll.verticalRulerView as? LineNumberRuler {
            ruler.ruleThickness = folding ? 70 : 48
            ruler.diffLineKinds = diffLineKinds
            ruler.toolTip = folding ? "点击箭头折叠或展开 JSON；同一行有多个容器时可选择目标" : nil
        }

        coordinator.invalidateFoldsIfNeeded()
        if let foldCommand, coordinator.foldCommandID != foldCommand.id {
            coordinator.foldCommandID = foldCommand.id
            coordinator.applyFoldCommand(foldCommand.action)
        }
        coordinator.decorate()
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
        var foldCommandID: UUID?
        var scrollObserver: NSObjectProtocol?
        var decoration: DispatchWorkItem?
        var foldModel = JSONFoldModel("")
        var lineIndex = TextLineIndex("")
        private var lineIndexSource = ""
        var foldScan: Task<JSONFoldModel, Never>?
        var foldScanSource: String?
        var foldScanRevision = 0
        var collapsed: Set<Int> = []

        init(_ parent: ToolTextEditor) {
            self.parent = parent
        }

        func cancelFoldScan() {
            foldScanRevision += 1
            foldScan?.cancel()
            foldScan = nil
            foldScanSource = nil
        }

        func updateLineIndexIfNeeded(_ source: String) {
            guard !lineIndexSource.utf16.elementsEqual(source.utf16) else { return }
            lineIndexSource = source
            lineIndex = TextLineIndex(source)
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
                view.needsDisplay = true
                view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            }
        }

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
                view.needsDisplay = true
            }
        }

        func isHidden(_ index: Int) -> Bool {
            let location = foldModel.ranges[index].location
            return collapsed.contains { other in
                other != index
                    && location > foldModel.ranges[other].location
                    && location < NSMaxRange(foldModel.ranges[other]) - 1
            }
        }

        func expandAll() {
            guard !collapsed.isEmpty, let view = textView else { return }
            collapsed.removeAll()
            refreshLayoutAndDisplay(in: view, characterRange: NSRange(location: 0, length: view.string.utf16.count))
        }

        func collapseToDepth(_ targetDepth: Int) {
            guard let view = textView, parent.folding else { return }
            if !foldModel.source.utf16.elementsEqual(view.string.utf16) {
                cancelFoldScan()
                foldModel = JSONFoldModel(view.string)
            }
            guard !foldModel.ranges.isEmpty else { return }

            let nextCollapsed = Set(
                foldModel.depths.enumerated().compactMap { index, depth in
                    depth >= targetDepth && foldModel.lineSpans[index] > 1 ? index : nil
                }
            )
            if nextCollapsed.isEmpty, targetDepth == 0 {
                return
            }
            collapsed = nextCollapsed
            let ranges = foldModel.ranges
            let caretLocation = view.selectedRange().location
            if let caretRange = collapsed.lazy.compactMap({ index -> NSRange? in
                let r = ranges[index]
                return (caretLocation > r.location && caretLocation < NSMaxRange(r) - 1) ? r : nil
            }).first {
                view.setSelectedRange(NSRange(location: caretRange.location, length: 0))
            }
            refreshLayoutAndDisplay(in: view, characterRange: NSRange(location: 0, length: view.string.utf16.count))
        }

        func applyFoldCommand(_ action: EditorFoldCommand.Action) {
            switch action {
            case .expandAll:
                expandAll()
            case .collapseAll:
                collapseToDepth(0)
            case .collapseToDepth(let depth):
                collapseToDepth(depth)
            }
        }

        func toggleFold(_ index: Int) {
            guard let view = textView, foldModel.ranges.indices.contains(index) else { return }
            if collapsed.contains(index) {
                collapsed.remove(index)
            } else {
                collapsed.insert(index)
            }
            let range = foldModel.ranges[index]
            if view.selectedRange().location > range.location && view.selectedRange().location < NSMaxRange(range) - 1 {
                view.setSelectedRange(NSRange(location: range.location, length: 0))
            }
            // Glyph and layout caches are independent; both must reflect the new visibility.
            refreshLayoutAndDisplay(in: view, characterRange: range)
        }

        private func refreshLayoutAndDisplay(in view: NSTextView, characterRange: NSRange) {
            view.layoutManager?.invalidateGlyphs(forCharacterRange: characterRange, changeInLength: 0, actualCharacterRange: nil)
            view.layoutManager?.invalidateLayout(forCharacterRange: characterRange, actualCharacterRange: nil)
            view.needsDisplay = true
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect rect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            guard !collapsed.isEmpty, glyphRange.length > 0 else { return false }
            let first = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let last = layoutManager.characterIndexForGlyph(at: NSMaxRange(glyphRange) - 1)
            guard collapsed.contains(where: { index in
                let range = foldModel.ranges[index]
                return first > range.location && last < NSMaxRange(range) - 1
            }) else { return false }
            rect.pointee.size.height = 0
            used.pointee.size.height = 0
            baselineOffset.pointee = 0
            return true
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard !collapsed.isEmpty else { return 0 }
            var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
            var newProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            var changed = false
            for i in 0..<glyphRange.length {
                let position = characterIndexes[i]
                // Keep newline control glyphs so TextKit can lay out and collapse their line fragments.
                if collapsed.contains(where: { index in
                    let range = foldModel.ranges[index]
                    return position > range.location && position < NSMaxRange(range) - 1
                }) && !newProperties[i].contains(.controlCharacter) {
                    newGlyphs[i] = 0
                    newProperties[i] = .null
                    changed = true
                }
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(
                &newGlyphs,
                properties: &newProperties,
                characterIndexes: characterIndexes,
                font: font,
                forGlyphRange: glyphRange
            )
            return glyphRange.length
        }

        func undoManager(for view: NSTextView) -> UndoManager? { parent.sharedUndoManager }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            expandAll()
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !updating, let textView else { return }
            parent.text = textView.string
            updateLineIndexIfNeeded(textView.string)
            invalidateFoldsIfNeeded()
            decorate()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textView.needsDisplay = true
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            guard !updating, let onCursorChange = parent.onCursorChange else { return }
            let source = textView.string
            updateLineIndexIfNeeded(source)
            let offset = min(textView.selectedRange().location, source.utf16.count)
            let position = EditorCursorPosition(
                line: lineIndex.lineNumber(atUTF16Offset: offset),
                column: lineIndex.column(atUTF16Offset: offset),
                utf16Offset: offset
            )
            DispatchQueue.main.async {
                onCursorChange(position)
            }
        }

        func decorate() {
            decoration?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyDecoration() }
            decoration = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        private func applyDecoration() {
            guard let view = textView, !view.hasMarkedText(), let layout = view.layoutManager else { return }
            let text = view.string
            updateLineIndexIfNeeded(text)
            scheduleFoldScan()
            if let ruler = view.enclosingScrollView?.verticalRulerView as? LineNumberRuler {
                ruler.updateLines(text)
            }
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true

            let count = text.utf16.count
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: count))
            guard parent.json, count > 0, let container = view.textContainer else { return }

            let glyphs = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
            let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let start = max(0, visible.location - 1024)
            let range = NSRange(location: start, length: min(count - start, min(visible.length + 2048, 32768)))
            let source = text as NSString
            let fragment = source.substring(with: range)
            let regex = try! NSRegularExpression(
                pattern: #""(?:\\.|[^"\\])*"|\b(?:true|false)\b|\bnull\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}\[\]:,]"#
            )
            for match in regex.matches(in: fragment, range: NSRange(location: 0, length: fragment.utf16.count)) {
                let token = (fragment as NSString).substring(with: match.range)
                let fullRange = NSRange(location: range.location + match.range.location, length: match.range.length)
                let color: NSColor
                switch token {
                case "{", "}", "[", "]", ":", ",":
                    color = ToolTheme.punctuationNS
                case "true", "false":
                    color = ToolTheme.booleanNS
                case "null":
                    color = ToolTheme.nullNS
                default:
                    if token.hasPrefix("\"") {
                        let suffixStart = NSMaxRange(fullRange)
                        let suffixLength = min(8, max(0, count - suffixStart))
                        let isKey = source
                            .substring(with: NSRange(location: suffixStart, length: suffixLength))
                            .trimmingCharacters(in: .whitespaces)
                            .hasPrefix(":")
                        color = isKey ? ToolTheme.keyNS : ToolTheme.stringNS
                    } else {
                        color = ToolTheme.numberNS
                    }
                }
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: fullRange)
            }
        }
    }
}

final class WorkspaceTextView: NSTextView {
    weak var coordinator: ToolTextEditor.Coordinator?
    var formatsWholeJSONPaste = false
    var showIndentGuides = false
    var diffLineKinds: [Int: JSONDifference.Kind] = [:]
    var onFocusChange: ((Bool) -> Void)?

    private var collapsedPillHits: [(index: Int, rect: NSRect)] = []
    private var hoveredPillIndex: Int?

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = collapsedPillHits.first(where: { $0.rect.contains(point) }) {
            if hoveredPillIndex != hit.index {
                hoveredPillIndex = hit.index
                needsDisplay = true
            }
            NSCursor.pointingHand.set()
            return
        }
        if hoveredPillIndex != nil {
            hoveredPillIndex = nil
            needsDisplay = true
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredPillIndex != nil {
            hoveredPillIndex = nil
            needsDisplay = true
        }
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = collapsedPillHits.first(where: { $0.rect.contains(point) }) {
            coordinator?.toggleFold(hit.index)
            return
        }
        super.mouseDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let source = string as NSString
        let hasActiveLine = selectedRange().length == 0
        coordinator?.updateLineIndexIfNeeded(string)
        let lineIndex = coordinator?.lineIndex ?? TextLineIndex(string)
        let activeLine = hasActiveLine ? lineIndex.lineNumber(atUTF16Offset: min(selectedRange().location, source.length)) : nil

        let needsFragments = showIndentGuides || !diffLineKinds.isEmpty || activeLine != nil
        guard needsFragments else { return }

        let glyphRange = layout.glyphRange(forBoundingRect: rect, in: container)
        let spaceWidth: CGFloat = showIndentGuides
            ? (" " as NSString).size(withAttributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
            : 0
        let guideBaseX = origin.x + container.lineFragmentPadding

        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, glyphs, _ in
            guard used.height > 0 else { return }
            let charRange = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let charStart = min(charRange.location, source.length)
            let line = lineIndex.lineNumber(atUTF16Offset: charStart)
            let bandRect = NSRect(x: self.bounds.minX, y: used.minY + origin.y - 1, width: self.bounds.width, height: used.height + 2)

            if let kind = self.diffLineKinds[line] {
                let fill: NSColor = switch kind {
                case .added: ToolTheme.diffAddedLineNS
                case .removed: ToolTheme.diffRemovedLineNS
                case .modified: ToolTheme.diffModifiedLineNS
                }
                fill.setFill()
                bandRect.fill()
            } else if activeLine == line {
                ToolTheme.activeLineNS.setFill()
                bandRect.fill()
            }

            if self.showIndentGuides, spaceWidth > 0, charStart < source.length {
                var leading = 0
                var cursor = charStart
                while cursor < source.length, leading < 32 {
                    let ch = source.character(at: cursor)
                    if ch == 32 { leading += 1; cursor += 1 }
                    else if ch == 9 { leading += 2; cursor += 1 }
                    else { break }
                }
                let stopCount = leading / 2
                if stopCount >= 1 {
                    ToolTheme.indentGuideNS.setFill()
                    let maxStop = stopCount == 1 && cursor < source.length ? 1 : stopCount
                    for step in 1...maxStop {
                        let x = floor(guideBaseX + CGFloat(step * 2) * spaceWidth) + 0.5
                        if step < stopCount || leading % 2 == 1 {
                            NSRect(x: x, y: used.minY + origin.y, width: 1, height: used.height + 4).fill()
                        }
                    }
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        collapsedPillHits.removeAll(keepingCapacity: true)

        guard let coordinator,
              coordinator.parent.folding,
              !coordinator.collapsed.isEmpty,
              let layout = layoutManager,
              let container = textContainer else { return }

        let origin = textContainerOrigin
        let visibleGlyphs = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleChars = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let pillFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        let pillTextColor = ToolTheme.foldCollapsedTextNS
        let sourceLength = (string as NSString).length

        for (index, range) in coordinator.foldModel.ranges.enumerated() {
            guard coordinator.collapsed.contains(index),
                  !coordinator.isHidden(index),
                  coordinator.foldModel.lineSpans.indices.contains(index),
                  coordinator.foldModel.lineSpans[index] > 1,
                  range.location < sourceLength else { continue }
            guard NSIntersectionRange(range, visibleChars).length > 0 || range.location >= visibleChars.location && range.location <= NSMaxRange(visibleChars) else {
                continue
            }

            let openGlyph = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            let openRect = layout.boundingRect(forGlyphRange: openGlyph, in: container)
            guard openRect.width > 0 || openRect.height > 0 else { continue }

            let summary = ("⋯ " + coordinator.foldModel.summaries[index]) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: pillTextColor]
            let textSize = summary.size(withAttributes: attrs)
            let pillHeight: CGFloat = 17
            let pillWidth = ceil(textSize.width) + 12
            let pillX = floor(openRect.maxX + origin.x + 6)
            let pillY = floor(openRect.minY + origin.y + (openRect.height - pillHeight) / 2)
            let pillRect = NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
            collapsedPillHits.append((index, pillRect))

            guard pillRect.intersects(dirtyRect) else { continue }

            let path = NSBezierPath(roundedRect: pillRect, xRadius: 4.5, yRadius: 4.5)
            ToolTheme.foldCollapsedFillNS.setFill()
            path.fill()
            if hoveredPillIndex == index {
                ToolTheme.foldCollapsedFillNS.setFill()
                path.fill()
            }
            ToolTheme.foldCollapsedBorderNS.setStroke()
            path.lineWidth = 0.5
            path.stroke()

            let textPoint = NSPoint(
                x: pillRect.minX + 6,
                y: pillRect.minY + floor((pillRect.height - textSize.height) / 2)
            )
            summary.draw(at: textPoint, withAttributes: attrs)
        }
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
    var diffLineKinds: [Int: JSONDifference.Kind] = [:] {
        didSet {
            if oldValue != diffLineKinds {
                needsDisplay = true
            }
        }
    }
    private var cachedText = ""
    private var lineIndex = TextLineIndex("")
    private var hoveredFoldLine: Int?

    func updateLines(_ text: String) {
        guard !cachedText.utf16.elementsEqual(text.utf16) else { return }
        cachedText = text
        lineIndex = TextLineIndex(text)
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = 48
        clientView = textView
    }

    required init(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let target = foldLineTarget(at: point)
        let nextLine = target?.line
        if hoveredFoldLine != nextLine {
            hoveredFoldLine = nextLine
            needsDisplay = true
        }
        if target != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredFoldLine != nil {
            hoveredFoldLine = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = foldLineTarget(at: point), let coordinator else { return }
        if target.candidates.count == 1 {
            coordinator.toggleFold(target.candidates[0])
            return
        }
        let menu = NSMenu()
        for index in target.candidates {
            let range = coordinator.foldModel.ranges[index]
            let snippet = (coordinator.foldModel.source as NSString)
                .substring(with: NSRange(location: range.location, length: min(range.length, 35)))
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let item = NSMenuItem(
                title: (coordinator.collapsed.contains(index) ? "展开 " : "折叠 ") + snippet,
                action: #selector(toggleMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleMenuItem(_ item: NSMenuItem) {
        coordinator?.toggleFold(item.tag)
    }

    private func foldLineTarget(at point: NSPoint) -> (line: Int, candidates: [Int])? {
        guard let text = textView,
              let layout = text.layoutManager,
              let container = text.textContainer,
              let coordinator,
              coordinator.parent.folding,
              point.x <= 32 else { return nil }
        let y = point.y + text.visibleRect.minY - text.textContainerInset.height
        layout.ensureLayout(for: container)
        guard y >= 0, y < layout.usedRect(for: container).maxY, layout.numberOfGlyphs > 0 else { return nil }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        let line = lineIndex.lineNumber(atUTF16Offset: layout.characterIndexForGlyph(at: glyph))
        let candidates = (coordinator.foldModel.byLine[line] ?? []).filter { !coordinator.isHidden($0) }
        guard !candidates.isEmpty else { return nil }
        return (line, candidates)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        ToolTheme.gutterNS.setFill()
        bounds.fill()

        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else {
            drawRightBorder()
            return
        }

        let source = text.string as NSString
        updateLines(text.string)
        let isFolding = coordinator?.parent.folding == true
        let activeLine: Int? = (text.isEditable && text.selectedRange().length == 0)
            ? lineIndex.lineNumber(atUTF16Offset: min(text.selectedRange().location, source.length))
            : nil

        let glyphRange = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        var previousLine = -1

        layout.enumerateLineFragments(forGlyphRange: glyphRange) { [self] _, used, _, glyphs, _ in
            guard used.height > 0 else { return }
            let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let line = lineIndex.lineNumber(atUTF16Offset: min(chars.location, source.length))
            guard line != previousLine else { return }
            previousLine = line

            let rowY = used.minY + text.textContainerInset.height - text.visibleRect.minY
            let rowHeight = used.height
            let isActive = activeLine == line

            if let kind = diffLineKinds[line] {
                let bandColor: NSColor = switch kind {
                case .added: ToolTheme.diffAddedLineNS
                case .removed: ToolTheme.diffRemovedLineNS
                case .modified: ToolTheme.diffModifiedLineNS
                }
                bandColor.setFill()
                NSRect(x: 0, y: rowY - 1, width: ruleThickness, height: rowHeight + 2).fill()

                let barColor: NSColor = switch kind {
                case .added: ToolTheme.diffAddedBarNS
                case .removed: ToolTheme.diffRemovedBarNS
                case .modified: ToolTheme.diffModifiedBarNS
                }
                barColor.setFill()
                NSRect(x: 0, y: rowY, width: 3, height: rowHeight).fill()
            } else if isActive {
                ToolTheme.activeLineNS.setFill()
                NSRect(x: 0, y: rowY - 1, width: ruleThickness, height: rowHeight + 2).fill()
            }

            let label = "\(line)" as NSString
            let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: isActive ? .medium : .regular)
            let labelColor = isActive ? ToolTheme.inkNS : ToolTheme.secondaryNS
            let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: labelColor]
            let labelSize = label.size(withAttributes: attributes)
            let inset: CGFloat = isFolding ? 8 : 10
            let labelY = rowY + floor((rowHeight - labelSize.height) / 2)
            label.draw(at: NSPoint(x: ruleThickness - labelSize.width - inset, y: labelY), withAttributes: attributes)

            if isFolding, let coordinator {
                let candidates = (coordinator.foldModel.byLine[line] ?? []).filter { !coordinator.isHidden($0) }
                if !candidates.isEmpty {
                    let isCollapsed = candidates.contains(where: { coordinator.collapsed.contains($0) })
                    let isHovered = hoveredFoldLine == line
                    let wellRect = NSRect(x: 6, y: rowY + floor((rowHeight - 20) / 2), width: 20, height: 20)

                    if isCollapsed {
                        let pillPath = NSBezierPath(roundedRect: wellRect, xRadius: 5, yRadius: 5)
                        ToolTheme.foldCollapsedFillNS.setFill()
                        pillPath.fill()
                        ToolTheme.foldCollapsedBorderNS.setStroke()
                        pillPath.lineWidth = 0.5
                        pillPath.stroke()
                    } else if isHovered {
                        let pillPath = NSBezierPath(roundedRect: wellRect, xRadius: 5, yRadius: 5)
                        ToolTheme.foldHoverFillNS.setFill()
                        pillPath.fill()
                    }

                    let chevron = NSBezierPath()
                    let cx = wellRect.midX
                    let cy = wellRect.midY
                    if isCollapsed {
                        chevron.move(to: NSPoint(x: cx - 2.5, y: cy - 4.5))
                        chevron.line(to: NSPoint(x: cx + 2.5, y: cy))
                        chevron.line(to: NSPoint(x: cx - 2.5, y: cy + 4.5))
                    } else {
                        chevron.move(to: NSPoint(x: cx - 4.5, y: cy - 2.0))
                        chevron.line(to: NSPoint(x: cx, y: cy + 2.5))
                        chevron.line(to: NSPoint(x: cx + 4.5, y: cy - 2.0))
                    }
                    chevron.lineWidth = 1.65
                    chevron.lineCapStyle = .round
                    chevron.lineJoinStyle = .round
                    let strokeColor: NSColor = if isCollapsed {
                        ToolTheme.foldCollapsedTextNS
                    } else if isHovered {
                        ToolTheme.inkNS
                    } else {
                        ToolTheme.secondaryNS
                    }
                    strokeColor.setStroke()
                    chevron.stroke()
                }
            }
        }

        drawRightBorder()
    }

    private func drawRightBorder() {
        ToolTheme.borderNS.setFill()
        NSRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
    }
}

struct JSONFoldModel: Sendable {
    let source: String
    let ranges: [NSRange]
    let depths: [Int]
    let summaries: [String]
    let lineSpans: [Int]
    let byLine: [Int: [Int]]

    init(_ source: String) {
        self.source = source
        guard let document = try? JSONDocument.parse(source) else {
            ranges = []
            depths = []
            summaries = []
            lineSpans = []
            byLine = [:]
            return
        }

        let lines = TextLineIndex(source)
        var found: [NSRange] = []
        var foundDepths: [Int] = []
        var foundSummaries: [String] = []
        var foundLineSpans: [Int] = []
        var pending: [(node: JSONNode, depth: Int)] = [(document.root, 0)]

        while let current = pending.popLast() {
            let node = current.node
            let depth = current.depth
            switch node.value {
            case .object(let members) where !members.isEmpty:
                let startLine = lines.lineNumber(atUTF16Offset: node.range.location)
                let endLine = lines.lineNumber(atUTF16Offset: max(node.range.location, NSMaxRange(node.range) - 1))
                let span = max(1, endLine - startLine + 1)
                found.append(node.range)
                foundDepths.append(depth)
                foundLineSpans.append(span)
                foundSummaries.append(span > 1 ? "\(members.count) 键 · \(span) 行" : "\(members.count) 键")
                pending.append(contentsOf: members.reversed().map { ($0.value, depth + 1) })
            case .array(let items) where !items.isEmpty:
                let startLine = lines.lineNumber(atUTF16Offset: node.range.location)
                let endLine = lines.lineNumber(atUTF16Offset: max(node.range.location, NSMaxRange(node.range) - 1))
                let span = max(1, endLine - startLine + 1)
                found.append(node.range)
                foundDepths.append(depth)
                foundLineSpans.append(span)
                foundSummaries.append(span > 1 ? "\(items.count) 项 · \(span) 行" : "\(items.count) 项")
                pending.append(contentsOf: items.reversed().map { ($0, depth + 1) })
            default:
                break
            }
        }

        ranges = found
        depths = foundDepths
        summaries = foundSummaries
        lineSpans = foundLineSpans

        var index: [Int: [Int]] = [:]
        for (i, range) in found.enumerated() {
            index[lines.lineNumber(atUTF16Offset: range.location), default: []].append(i)
        }
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
