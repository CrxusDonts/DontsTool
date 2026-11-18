import AppKit
import DontsToolCore
import SwiftUI

/// 独立设置窗口：820 × 620，标准标题栏 + SwiftUI 内容（design/05-settings.html）。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let navigation = SettingsNavigationState()
    init(
        updates: AppUpdateController,
        settings: SettingsStore,
        websites: WebsiteShortcutStore,
        searchEngines: SearchEngineStore,
        notes: LocalNoteStore,
        sync: CloudSyncCoordinator,
        login: LoginItemManager,
        secrets: SecretStoring,
        appIndex: AppIndex,
        selectionTranslation: SelectionTranslationController,
        onRescan: @escaping () -> Void,
        onHotKeyRecordingChanged: @escaping (Bool) -> Void,
        prepareBackup: @escaping @MainActor () async -> Void,
        didRestoreBackup: @escaping @MainActor () -> Void
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
            updates: updates,
            settings: settings,
            websites: websites,
            searchEngines: searchEngines,
            notes: notes,
            sync: sync,
            login: login,
            secrets: secrets,
            appIndex: appIndex,
            selectionTranslation: selectionTranslation,
            navigation: navigation,
            onRescan: onRescan,
            onHotKeyRecordingChanged: onHotKeyRecordingChanged,
            prepareBackup: prepareBackup,
            didRestoreBackup: didRestoreBackup
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

    func showTranslation() {
        navigation.tab = .translation
        show()
    }
}
