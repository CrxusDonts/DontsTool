import AppKit
import Combine
import DontsToolCore

@MainActor
final class AppController {
    private let settings = SettingsStore()
    private let usage = UsageStore()
    private let searchEngines = SearchEngineStore()
    private lazy var websites = WebsiteShortcutStore(reservedKeywords: { [weak self] in
        guard let self else { return [] }
        return SearchEngineKeywordRules.reservedWebsiteKeywords(for: self.searchEngines.configuration)
    })
    private var websitesCancellable: AnyCancellable?
    private var searchEnginesCancellable: AnyCancellable?
    private let notes = LocalNoteStore()
    private var noteWindows: LocalNoteWindowManager?
    private var enabledProvidersCancellable: AnyCancellable?
    private var notesCancellable: AnyCancellable?
    private let appIndex = AppIndex()
    private var appIndexCancellable: AnyCancellable?
    private var applicationActivityCancellable: AnyCancellable?
    private var applicationSortCancellable: AnyCancellable?
    private let hotKeyManager = HotKeyManager()
    private let doubleTapMonitor = ModifierDoubleTapMonitor()
    private let toast = ToastPresenter()
    private var menuBar: MenuBarController?
    private var panel: LauncherPanelController?
    private var coordinator: SearchCoordinator?
    private var toolWindows: ToolWindowManager?
    private var selectionTranslation: SelectionTranslationController?
    private var knowledgeWindows: KnowledgeWindowManager?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var hotKeyCancellable: AnyCancellable?
    private var activeHotKey: SettingsStore.HotKeyConfiguration?
    private var isRecordingHotKey = false

    func start() {
        let prefiller = PanelPrefiller()
        let progress = PanelProgressReporter()
        let settingsOpener = PanelSettingsOpener()
        let secrets = KeychainSecretStore()
        let login = LoginItemManager()
        let clipboard = SystemClipboard()
        let appProvider = AppProvider(
            index: appIndex,
            settings: settings,
            usage: usage,
            launcher: SystemAppLauncher(),
            feedback: toast,
            clipboard: clipboard
        )
        let translator = RemoteTranslationService(settings: settings, secrets: secrets)
        let toolWindows = ToolWindowManager(settings: settings, translator: translator)
        self.toolWindows = toolWindows
        let selectionTranslation = SelectionTranslationController(settings: settings, translator: translator,
            gestureVerificationOnly: CommandLine.arguments.contains("--verify-right-press"))
        self.selectionTranslation = selectionTranslation
        let knowledgeWindows = KnowledgeWindowManager(settings: settings)
        self.knowledgeWindows = knowledgeWindows
        let knowledgeProvider = KnowledgeProvider(settings: settings, service: knowledgeWindows)
        let noteWindows = LocalNoteWindowManager(store: notes)
        self.noteWindows = noteWindows
        let notesProvider = NotesProvider(settings: settings, store: notes, opener: noteWindows, unavailableKeywords: { [weak self] in
            guard let self else { return [] }
            return Set(self.websites.configuration.groups.map(\.keyword) + self.searchEngines.configuration.engines.map(\.keyword))
        })
        let textProvider = TextToolsProvider(settings: settings, toolOpener: toolWindows)
        let webProvider = WebSearchProvider(
            settings: settings,
            engines: searchEngines,
            usage: usage,
            opener: SystemURLOpener(),
            feedback: toast,
            prefill: prefiller,
            clipboard: clipboard,
            unavailableKeywords: { [weak websites] in Set(websites?.configuration.groups.map(\.keyword) ?? []) }
        )
        let fileProvider = FileProvider(
            settings: settings,
            usage: usage,
            launcher: SystemAppLauncher(),
            feedback: toast,
            clipboard: clipboard
        )
        let translationProvider = TranslationProvider(settings: settings, toolOpener: toolWindows)
        let calculatorProvider = CalculatorProvider(settings: settings, clipboard: clipboard, feedback: toast)
        let quickOpenProvider = QuickOpenProvider(
            settings: settings,
            usage: usage,
            launcher: SystemAppLauncher(),
            opener: SystemURLOpener(),
            clipboard: clipboard,
            feedback: toast
        )
        let websiteProvider = WebsiteShortcutProvider(store: websites, opener: SystemURLOpener(), feedback: toast, prefill: prefiller)
        let geminiService = GeminiConversationService(controller: SystemGeminiAppController())
        let geminiProvider = GeminiProvider(index: appIndex, settings: settings, service: geminiService, feedback: toast)
        let ideaProvider = IDEProjectProvider(index: appIndex, settings: settings, usage: usage, feedback: toast)
        let registry = ToolRegistry(providers: [
            appProvider, fileProvider, textProvider, webProvider, translationProvider,
            knowledgeProvider, notesProvider, websiteProvider, calculatorProvider, quickOpenProvider, geminiProvider, ideaProvider
        ])
        let coordinator = SearchCoordinator(registry: registry)
        let contentProvider = ContentActionProvider(settings: settings, toolOpener: toolWindows,
            urlOpener: SystemURLOpener(), feedback: toast)
        let panel = LauncherPanelController(
            registry: registry,
            coordinator: coordinator,
            toast: toast,
            hotKeyDisplay: HotKeyFormatter.displayString(for: settings.hotKey),
            settings: settings,
            contentProvider: contentProvider
        )
        prefiller.panel = panel
        selectionTranslation.onSuppressedMouseDown = { [weak panel] in
            panel?.hide(restorePreviousApp: false)
        }
        progress.panel = panel
        settingsOpener.panel = panel
        panel.onRescanApps = { [weak self] in
            self?.rescanApps()
        }
        let settingsWindow = SettingsWindowController(
            settings: settings,
            websites: websites,
            searchEngines: searchEngines,
            login: login,
            secrets: secrets,
            appIndex: appIndex,
            selectionTranslation: selectionTranslation,
            onRescan: { [weak self] in self?.rescanApps() },
            onHotKeyRecordingChanged: { [weak self] isRecording in
                self?.setHotKeyRecording(isRecording)
            }
        )
        panel.onOpenSettings = { [weak settingsWindow] in
            settingsWindow?.show()
        }
        toolWindows.onOpenSettings = { [weak settingsWindow] in settingsWindow?.showTranslation() }
        knowledgeWindows.onOpenSettings = { [weak settingsWindow] in settingsWindow?.show() }
        knowledgeWindows.onSearchChanged = { [weak panel] in panel?.refreshSearch() }
        self.settingsWindow = settingsWindow
        selectionTranslation.onOpenSettings = { [weak settingsWindow] in settingsWindow?.showTranslation() }
        selectionTranslation.onEditSource = { [weak toolWindows] text in
            toolWindows?.openTool(ToolOpenRequest(kind: .translation, input: text))
        }
        self.coordinator = coordinator
        self.panel = panel
        enabledProvidersCancellable = settings.$enabledProviderIDs.dropFirst().sink { [weak panel] _ in
            DispatchQueue.main.async { panel?.refreshSearch() }
        }
        notesCancellable = notes.$notes.dropFirst().sink { [weak panel] _ in
            DispatchQueue.main.async { panel?.refreshSearch() }
        }
        websitesCancellable = websites.$configuration.dropFirst().sink { [weak panel] _ in
            DispatchQueue.main.async { panel?.refreshSearch() }
        }
        searchEnginesCancellable = searchEngines.$configuration.dropFirst().sink { [weak panel] _ in
            DispatchQueue.main.async { panel?.refreshSearch() }
        }
        toolWindows.onDocumentsChanged = { [weak panel] in panel?.refreshSearch() }
        appIndexCancellable = appIndex.$apps.dropFirst().sink { [weak panel] _ in
            DispatchQueue.main.async { panel?.refreshSearch() }
        }
        applicationSortCancellable = settings.$applicationSortOrder.dropFirst().sink { [weak panel] _ in
            DispatchQueue.main.async { panel?.refreshSearch() }
        }
        applicationActivityCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier != Bundle.main.bundleIdentifier,
                      let url = application.bundleURL, url.pathExtension.lowercased() == "app" else { return }
                let path = url.standardizedFileURL.path
                MainActor.assumeIsolated { self?.usage.recordActivation(of: path) }
            }

        let menuBar = MenuBarController()
        menuBar.onOpenLauncher = { [weak panel] in panel?.toggle() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.hotKeyDisplay = HotKeyFormatter.displayString(for: settings.hotKey)
        menuBar.install()
        self.menuBar = menuBar

        hotKeyManager.onHotKey = { [weak panel] in panel?.toggle() }
        hotKeyCancellable = settings.hotKeyChanges
            .removeDuplicates()
            .sink { [weak self] configuration in
                guard let self else { return }
                if self.isRecordingHotKey {
                    self.updateHotKeyDisplay(configuration)
                } else if configuration == self.activeHotKey {
                    self.updateHotKeyDisplay(configuration)
                } else {
                    self.applyHotKey(configuration)
                }
            }
        applyHotKey(settings.hotKey)

        Task {
            await appIndex.scan()
            panel.refreshSearch()
        }

        if let flag = CommandLine.arguments.firstIndex(of: "--tool"),
           CommandLine.arguments.indices.contains(flag + 1),
           let kind = ToolKind(rawValue: CommandLine.arguments[flag + 1]) {
            toolWindows.openTool(ToolOpenRequest(kind: kind))
        }

        if let flag = CommandLine.arguments.firstIndex(of: "--knowledge"),
           CommandLine.arguments.indices.contains(flag + 1),
           let surface = KnowledgeSurface(rawValue: CommandLine.arguments[flag + 1]) {
            knowledgeWindows.openKnowledge(.init(surface: surface))
        }

        if CommandLine.arguments.contains("--new-note") { noteWindows.createNote() }

        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak panel] in
                panel?.show()
            }
        }

        if !settings.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showOnboarding()
            }
        }

        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak settingsWindow] in
                settingsWindow?.show()
            }
        }

    }

    var needsTerminationPreparation: Bool { (knowledgeWindows?.hasOpenWindows ?? false) || (noteWindows?.hasOpenWindows ?? false) }

    func prepareToTerminate() async -> Bool {
        guard await noteWindows?.prepareToTerminate() ?? true else { return false }
        let approved = await knowledgeWindows?.prepareToTerminate() ?? true
        if !approved { noteWindows?.resumeEditing() }
        return approved
    }

    func shutdown() {
        appIndex.stopMonitoring()
        appIndexCancellable?.cancel()
        applicationActivityCancellable?.cancel()
        applicationSortCancellable?.cancel()
        selectionTranslation?.shutdown()
        doubleTapMonitor.stop()
        usage.flush()
        noteWindows?.shutdown()
        toolWindows?.shutdown()
        knowledgeWindows?.shutdown()
    }

    private func setHotKeyRecording(_ isRecording: Bool) {
        isRecordingHotKey = isRecording
        if isRecording {
            hotKeyManager.unregister()
            doubleTapMonitor.stop()
        } else {
            applyHotKey(settings.hotKey)
        }
    }

    private func applyHotKey(_ configuration: SettingsStore.HotKeyConfiguration) {
        hotKeyManager.unregister()
        doubleTapMonitor.stop()

        switch configuration.kind {
        case .doubleTap:
            guard let modifier = configuration.doubleTapModifier else {
                activeHotKey = nil
                updateHotKeyDisplay(configuration)
                toast.show("无效的双击快捷键配置")
                return
            }
            let previous = activeHotKey
            let started = doubleTapMonitor.start(modifier: modifier) { [weak self] in
                self?.panel?.toggle()
            }
            if started {
                activeHotKey = configuration
            } else {
                activeHotKey = nil
                // 监听创建失败时保留一个可用的组合键，避免把用户锁在应用外。
                let fallback = (previous?.kind == .combination ? previous : nil) ?? .optionSpace
                if restore(fallback) {
                    activeHotKey = fallback
                    Log.app.error("双击热键监听启动失败")
                    toast.show("双击快捷键启动失败，暂时使用 \(HotKeyFormatter.displayString(for: fallback))")
                } else {
                    Log.app.error("双击热键监听启动失败且无可用回退")
                    toast.show("无法启动双击快捷键监听")
                }
            }
            updateHotKeyDisplay(configuration)

        case .combination:
            do {
                try hotKeyManager.register(configuration)
                activeHotKey = configuration
                updateHotKeyDisplay(configuration)
            } catch {
                Log.app.error("全局热键注册失败: \(error.localizedDescription, privacy: .public)")
                if let fallback = activeHotKey, restore(fallback) {
                    activeHotKey = fallback
                    // @Published 在 willSet 阶段发值，settings.hotKey 此时仍是旧值；
                    // 不能用它判断是否需要回退，否则会把冲突组合留在持久化存储里。
                    settings.setHotKey(fallback)
                    updateHotKeyDisplay(fallback)
                } else {
                    activeHotKey = nil
                    updateHotKeyDisplay(configuration)
                }
                toast.show(error.localizedDescription)
            }
        }
    }

    private func restore(_ configuration: SettingsStore.HotKeyConfiguration) -> Bool {
        switch configuration.kind {
        case .combination:
            do {
                try hotKeyManager.register(configuration)
                return true
            } catch {
                return false
            }
        case .doubleTap:
            guard let modifier = configuration.doubleTapModifier else { return false }
            return doubleTapMonitor.start(modifier: modifier) { [weak self] in
                self?.panel?.toggle()
            }
        }
    }

    private func updateHotKeyDisplay(_ configuration: SettingsStore.HotKeyConfiguration) {
        let display = HotKeyFormatter.displayString(for: configuration)
        menuBar?.hotKeyDisplay = display
        panel?.updateHotKeyDisplay(display)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(
                hotKeyDisplay: HotKeyFormatter.displayString(for: settings.hotKey),
                onOpenSettings: { [weak self] in
                    self?.settingsWindow?.show()
                },
                onDismiss: { [weak self] in
                    self?.settings.completeOnboarding()
                }
            )
        }
        onboardingWindow?.show()
    }

    private func rescanApps() {
        Task { @MainActor in
            await appIndex.scan()
            toast.show("已索引 \(appIndex.apps.count) 个应用")
            panel?.refreshSearch()
        }
    }
}

@MainActor
final class PanelPrefiller: QueryPrefilling {
    weak var panel: LauncherPanelController?

    func prefill(_ query: String) {
        panel?.prefill(query)
    }
}

@MainActor
final class PanelSettingsOpener: SettingsOpening {
    weak var panel: LauncherPanelController?

    func openSettings() {
        panel?.onOpenSettings?()
    }
}

@MainActor
final class PanelProgressReporter: OperationProgressReporting {
    weak var panel: LauncherPanelController?

    func begin(_ message: String) {
        panel?.begin(message)
    }

    func end() {
        panel?.end()
    }
}
