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
        aiService: RemoteAIChatService,
        aiConsumers: AIConsumerRegistry,
        appIndex: AppIndex,
        selectionTranslation: SelectionTranslationController,
        pluginManager: PluginManager,
        pluginSettings: PluginSettingsStore,
        pluginSources: PluginSourceStore,
        pluginInstaller: PluginInstaller,
        onRescan: @escaping () -> Void,
        onReloadPlugins: @escaping () -> Void,
        onHotKeyRecordingChanged: @escaping (Bool) -> Void,
        onTryGuideQuery: @escaping (String) -> Void,
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
            aiService: aiService,
            aiConsumers: aiConsumers,
            appIndex: appIndex,
            selectionTranslation: selectionTranslation,
            pluginManager: pluginManager,
            pluginSettings: pluginSettings,
            pluginSources: pluginSources,
            pluginInstaller: pluginInstaller,
            navigation: navigation,
            onRescan: onRescan,
            onReloadPlugins: onReloadPlugins,
            onHotKeyRecordingChanged: onHotKeyRecordingChanged,
            onTryGuideQuery: onTryGuideQuery,
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

    func showAIModels() {
        navigation.tab = .aiModels
        show()
    }

    func showTranslation() {
        navigation.tab = .translation
        show()
    }

    func showGuide(query: String = "") {
        navigation.guideSearchQuery = query
        navigation.tab = .guide
        show()
    }
}
