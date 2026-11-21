import AppKit
import SwiftUI

@MainActor
final class QuickAIComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onNewWindow: (() -> Void)?

    var isComposing: Bool {
        hasMarkedText()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.intersection([.command, .shift, .option, .control]) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "n" {
            onNewWindow?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return / Numpad Enter
            if flags.contains(.shift) {
                insertNewline(nil)
            } else if flags.intersection([.command, .option, .control]).isEmpty {
                onSubmit?()
            } else {
                super.keyDown(with: event)
            }
        case 53: // Escape
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}

struct QuickAIComposerView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isDisabled: Bool
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onNewWindow: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = QuickAIComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13.5, weight: .regular)
        textView.textColor = Theme.inkNS
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("AI 提问输入框")

        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.handleSubmit()
        }
        textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.handleEscape()
        }
        textView.onNewWindow = { [weak coordinator = context.coordinator] in
            coordinator?.handleNewWindow()
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView

        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? QuickAIComposerTextView else { return }
        textView.isEditable = !isDisabled
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QuickAIComposerView
        weak var textView: QuickAIComposerTextView?

        init(parent: QuickAIComposerView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? QuickAIComposerTextView else { return }
            guard !textView.hasMarkedText() else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }

        func handleSubmit() {
            guard let textView else { return }
            guard !textView.hasMarkedText() else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            parent.onSubmit()
        }

        func handleEscape() {
            guard textView?.hasMarkedText() != true else { return }
            parent.onEscape()
        }

        func handleNewWindow() {
            guard textView?.hasMarkedText() != true else { return }
            parent.onNewWindow()
        }
    }
}
