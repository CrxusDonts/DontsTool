import AppKit
import DontsToolCore
import SwiftUI

/// 独立设置窗口：820 × 620，标准标题栏 + SwiftUI 内容（design/05-settings.html）。
@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        settings: SettingsStore,
        websites: WebsiteShortcutStore,
        login: LoginItemManager,
        secrets: SecretStoring,
        appIndex: AppIndex,
        onRescan: @escaping () -> Void,
        onHotKeyRecordingChanged: @escaping (Bool) -> Void
    ) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.settingsSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DontsTool 设置"
        window.setContentSize(Metrics.settingsSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsRootView(
            settings: settings,
            websites: websites,
            login: login,
            secrets: secrets,
            appIndex: appIndex,
            onRescan: onRescan,
            onHotKeyRecordingChanged: onHotKeyRecordingChanged
        ))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
