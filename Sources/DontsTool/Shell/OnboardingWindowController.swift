import AppKit
import DontsToolCore
import SwiftUI

/// 轻量欢迎窗口：首次启动或菜单栏「使用说明」打开。
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onDismiss: () -> Void

    init(hotKeyDisplay: String, onOpenSettings: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 460, height: 320)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(
            hotKeyDisplay: hotKeyDisplay,
            onOpenSettings: onOpenSettings,
            onDismiss: { [weak window] in
                window?.close()
            }
        ))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onDismiss()
    }
}
