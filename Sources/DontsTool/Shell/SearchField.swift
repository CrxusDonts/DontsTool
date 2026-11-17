import AppKit

final class SearchField: NSSearchField, NSSearchFieldDelegate {
    var onTextChange: ((String) -> Void)?
    var onCompositionBegin: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onSecondaryConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRescan: (() -> Void)?
    var onShowActions: (() -> Void)?
    var onCopyFilePath: (() -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        placeholderAttributedString = NSAttributedString(
            string: "搜索应用、工具、网址…",
            attributes: [
                .foregroundColor: Theme.tertiaryNS,
                .font: NSFont.systemFont(ofSize: 17, weight: .regular)
            ]
        )
        font = .systemFont(ofSize: 17, weight: .regular)
        textColor = Theme.inkNS
        isBezeled = false
        drawsBackground = false
        sendsWholeSearchString = false
        sendsSearchStringImmediately = true
        focusRingType = .none
        // 搜索与清除图标由外层 SwiftUI 搜索头统一提供。
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        setAccessibilityLabel("搜索")
        setAccessibilityHelp("输入应用名或工具关键词；file 加文件名搜索文件；文件结果支持 ⌘回车定位、⌘⇧C 复制路径；上下箭头选择，回车执行，⌘K 查看操作，esc 关闭")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContentMode(_ enabled: Bool) {
        placeholderAttributedString = NSAttributedString(
            string: enabled ? "筛选可用操作…" : "搜索应用、工具、网址…",
            attributes: [.foregroundColor: Theme.tertiaryNS, .font: NSFont.systemFont(ofSize: 17)]
        )
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isComposing else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.intersection([.command, .shift, .option, .control]) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "c", !isComposing,
           onCopyFilePath?() == true { return true }
        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case ",":
            onOpenSettings?()
            return true
        case "k":
            onShowActions?()
            return true
        case "r":
            onRescan?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if isComposing {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 126:
            onMoveUp?()
        case 125:
            onMoveDown?()
        case 36:
            if event.modifierFlags.contains(.command) {
                onSecondaryConfirm?()
            } else {
                onConfirm?()
            }
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if isComposing { onCompositionBegin?(); return }
        onTextChange?(stringValue)
    }

    var isComposing: Bool {
        (currentEditor() as? NSTextView)?.hasMarkedText() == true
            || (currentEditor() as? LauncherFieldEditor)?.isUpdatingComposition == true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText(), !isComposing else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            onMoveUp?()
            return true
        case #selector(NSResponder.moveDown(_:)):
            onMoveDown?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                onSecondaryConfirm?()
            } else {
                onConfirm?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

/// Only intercept an explicit paste into an empty launcher field. Other editing,
/// shortcuts and Chinese marked-text behaviour remain NSTextView's own.
final class LauncherFieldEditor: NSTextView {
    var onPasteContent: ((String) -> Bool)?
    var pasteboardForPaste: () -> NSPasteboard = { .general }
    var onCompositionChange: ((Bool, String) -> Void)?
    private var compositionEditDepth = 0
    var isUpdatingComposition: Bool { compositionEditDepth > 0 }

    override func setMarkedText(_ text: Any, selectedRange: NSRange, replacementRange: NSRange) {
        onCompositionChange?(true, string)
        compositionEditDepth += 1
        super.setMarkedText(text, selectedRange: selectedRange, replacementRange: replacementRange)
        finishCompositionEdit()
    }

    override func unmarkText() {
        guard hasMarkedText() || isUpdatingComposition else { super.unmarkText(); return }
        compositionEditDepth += 1
        super.unmarkText()
        finishCompositionEdit()
    }

    override func insertText(_ text: Any, replacementRange: NSRange) {
        guard hasMarkedText() || isUpdatingComposition else {
            super.insertText(text, replacementRange: replacementRange)
            return
        }
        compositionEditDepth += 1
        super.insertText(text, replacementRange: replacementRange)
        finishCompositionEdit()
    }

    private func finishCompositionEdit() {
        compositionEditDepth -= 1
        // AppKit may call unmarkText from inside insertText. Publish only after
        // the outer edit has applied the final candidate, never its intermediate text.
        if compositionEditDepth == 0 { onCompositionChange?(hasMarkedText(), string) }
    }

    override func paste(_ sender: Any?) {
        if attachPastedContent() { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if attachPastedContent() { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        if attachPastedContent() { return }
        super.pasteAsRichText(sender)
    }

    private func attachPastedContent() -> Bool {
        guard string.isEmpty, !hasMarkedText(),
              let text = pasteboardForPaste().string(forType: .string) else { return false }
        return onPasteContent?(text) == true
    }
}
