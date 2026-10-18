import AppKit

final class SearchField: NSSearchField, NSSearchFieldDelegate {
    var onTextChange: ((String) -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onSecondaryConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRescan: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        placeholderAttributedString = NSAttributedString(
            string: "搜索应用、文件或输入关键词…",
            attributes: [
                .foregroundColor: Theme.tertiaryNS,
                .font: NSFont.systemFont(ofSize: 20, weight: .regular)
            ]
        )
        font = .systemFont(ofSize: 20, weight: .regular)
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
        setAccessibilityHelp("输入应用名、文件名或关键词；上下箭头选择，回车执行，esc 关闭")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case ",":
            onOpenSettings?()
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
        if isComposing { return }
        onTextChange?(stringValue)
    }

    private var isComposing: Bool {
        (currentEditor() as? NSTextView)?.hasMarkedText() == true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
