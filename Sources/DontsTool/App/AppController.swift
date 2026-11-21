import AppKit
import Combine
import DontsToolCore

@MainActor
final class AppController {
    private(set) lazy var updateController = AppUpdateController(resumeAfterFailure: { [weak self] in
        self?.noteWindows?.resumeEditing()
    }, prepareToInstall: { [weak self] in
        await self?.prepareToTerminate() ?? false
    })
    private lazy var termination = TerminationPreparation(prepare: { [weak self] in
        guard let self else { return false }
        return await noteWindows?.prepareToTerminate() ?? true
    })
    private let settings = SettingsStore()
    private let pluginSettings = PluginSettingsStore()
    private let pluginSources = PluginSourceStore()
    private let usage = UsageStore()
    private let searchEngines = SearchEngineStore()
    private lazy var websites = WebsiteShortcutStore(reservedKeywords: { [weak self] in
        guard let self else { return [] }
        return SearchEngineKeywordRules.reservedWebsiteKeywords(for: self.searchEngines.configuration)
    })
    private let notes = LocalNoteStore()
    private var noteWindows: LocalNoteWindowManager?
    private let appIndex = AppIndex()
    private var searchRefreshCancellables = Set<AnyCancellable>()
    private let toast = ToastPresenter()
    private var hotKeyCoordinator: HotKeyBindingCoordinator?
    private var menuBar: MenuBarController?
    private var panel: LauncherPanelController?
    private var coordinator: SearchCoordinator?
    private var pluginManager: PluginManager?
    private var pluginInstaller: PluginInstaller?
    private var toolWindows: ToolWindowManager?
    private var quickAIWindows: QuickAIWindowManager?
    private var selectionTranslation: SelectionTranslationController?
    private var cloudSync: CloudSyncCoordinator?
    private var wakeObserver: NSObjectProtocol?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?

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
        let aiService = RemoteAIChatService(settings: settings, secrets: secrets)
        let toolWindows = ToolWindowManager(settings: settings, translator: translator, usage: usage)
        self.toolWindows = toolWindows
        let quickAIWindows = QuickAIWindowManager(aiService: aiService, usage: usage)
        self.quickAIWindows = quickAIWindows
        let selectionTranslation = SelectionTranslationController(settings: settings, translator: translator,
            gestureVerificationOnly: CommandLine.arguments.contains("--verify-right-press"))
        self.selectionTranslation = selectionTranslation
        let noteWindows = LocalNoteWindowManager(store: notes)
        self.noteWindows = noteWindows
        let cloudSync = CloudSyncCoordinator(
            settings: settings,
            websites: websites,
            searchEngines: searchEngines,
            notes: notes,
            secrets: secrets
        )
        cloudSync.prepareNotesForSync = { [weak noteWindows] in
            await noteWindows?.flushOpenNotes()
        }
        self.cloudSync = cloudSync
        let notesProvider = NotesProvider(
            settings: settings,
            store: notes,
            opener: noteWindows,
            clipboard: clipboard,
            feedback: toast,
            usage: usage,
            unavailableKeywords: { [weak self] in
                guard let self else { return [] }
                return Set(self.websites.configuration.groups.map(\.keyword) + self.searchEngines.configuration.engines.map(\.keyword))
            }
        )
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
        let terminalService = SystemTerminalFinderService()
        let openInTerminal: @MainActor (URL) async throws -> Void = { [weak settings] url in
            let preferred = settings?.preferredTerminalBundleID ?? ""
            try await terminalService.openPathInPreferredTerminal(url, configuredBundleID: preferred)
        }
        let translationProvider = TranslationProvider(settings: settings, toolOpener: toolWindows)
        let calculatorProvider = CalculatorProvider(settings: settings, clipboard: clipboard, feedback: toast)
        let appLauncher = SystemAppLauncher()
        let quickOpenProvider = QuickOpenProvider(
            settings: settings,
            usage: usage,
            launcher: appLauncher,
            opener: SystemURLOpener(),
            clipboard: clipboard,
            feedback: toast,
            openInTerminal: openInTerminal
        )
        let websiteProvider = WebsiteShortcutProvider(store: websites, opener: SystemURLOpener(), feedback: toast, prefill: prefiller)
        let openAI: @MainActor (QuickAIRequest) -> Void = { [weak quickAIWindows] request in
            quickAIWindows?.open(request)
        }
        let helpGuideProvider = HelpGuideProvider(
            openGuide: { [weak self] query in
                self?.settingsWindow?.showGuide(query: query)
            },
            prefill: prefiller,
            unavailableKeywords: { [weak self] in
                guard let self else { return [] }
                return Set(self.websites.configuration.groups.map(\.keyword) + self.searchEngines.configuration.engines.map(\.keyword))
            }
        )
        let registry = ToolRegistry(providers: [
            appProvider, textProvider, webProvider, translationProvider,
            notesProvider, websiteProvider, calculatorProvider, quickOpenProvider,
            helpGuideProvider
        ])
        let coordinator = SearchCoordinator(registry: registry, usage: usage)
        let contentProvider = ContentActionProvider(
            settings: settings,
            toolOpener: toolWindows,
            urlOpener: SystemURLOpener(),
            feedback: toast,
            noteOpener: noteWindows,
            openAI: openAI
        )
        let panel = LauncherPanelController(
            registry: registry,
            coordinator: coordinator,
            toast: toast,
            hotKeyDisplay: HotKeyFormatter.displayString(for: settings.hotKey),
            settings: settings,
            contentProvider: contentProvider
        )
        let hostContext = PluginHostContext(
            settings: settings,
            pluginSettings: pluginSettings,
            usage: usage,
            clipboard: clipboard,
            urlOpener: SystemURLOpener(),
            appLauncher: appLauncher,
            feedback: toast,
            prefill: prefiller,
            secrets: secrets,
            unavailableKeywords: { [weak self] in
                guard let self else { return [] }
                return Set(self.websites.configuration.groups.map(\.keyword) + self.searchEngines.configuration.engines.map(\.keyword))
            },
            refreshSearch: { [weak panel] in
                panel?.refreshSearch()
            },
            openInTerminal: openInTerminal,
            hostVersion: AppInfo.version,
            openAI: openAI
        )
        let pluginManager = PluginManager(
            bundledDirectory: Bundle.main.resourceURL?.appendingPathComponent("BundledPlugins", isDirectory: true),
            userDirectory: PluginManager.defaultUserPluginsDirectory(),
            helpersDirectory: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true),
            registry: registry,
            hostContext: hostContext
        )
        self.pluginManager = pluginManager
        pluginManager.loadAll()

        let pluginInstaller = PluginInstaller(pluginManager: pluginManager)
        self.pluginInstaller = pluginInstaller

        prefiller.panel = panel
        selectionTranslation.onSuppressedMouseDown = { [weak panel] in
            panel?.hide(restorePreviousApp: false)
        }
        progress.panel = panel
        settingsOpener.panel = panel
        panel.onRescanApps = { [weak self] in
            self?.rescanApps()
        }
        let hotKeyCoordinator = HotKeyBindingCoordinator(settings: settings, toast: toast)
        self.hotKeyCoordinator = hotKeyCoordinator
        let settingsWindow = SettingsWindowController(
            updates: updateController,
            settings: settings,
            websites: websites,
            searchEngines: searchEngines,
            notes: notes,
            sync: cloudSync,
            login: login,
            secrets: secrets,
            appIndex: appIndex,
            selectionTranslation: selectionTranslation,
            pluginManager: pluginManager,
            pluginSettings: pluginSettings,
            pluginSources: pluginSources,
            pluginInstaller: pluginInstaller,
            onRescan: { [weak self] in self?.rescanApps() },
            onReloadPlugins: { [weak pluginManager, weak toast] in
                guard let pluginManager else { return }
                pluginManager.reload()
                let loadedCount = pluginManager.records.filter { $0.status == .loaded }.count
                toast?.show("已重新加载 \(loadedCount) 个插件")
            },
            onHotKeyRecordingChanged: { [weak hotKeyCoordinator] isRecording in
                hotKeyCoordinator?.setRecording(isRecording)
            },
            onTryGuideQuery: { [weak panel] query in
                panel?.showAndPrefill(query)
            },
            prepareBackup: { [weak noteWindows] in
                await noteWindows?.flushOpenNotes()
            },
            didRestoreBackup: { [weak noteWindows, weak panel] in
                noteWindows?.reconcileWithStore()
                panel?.refreshSearch()
            }
        )
        cloudSync.didApplyRemoteNotes = { [weak noteWindows, weak panel] in
            noteWindows?.reconcileWithStore()
            panel?.refreshSearch()
        }
        cloudSync.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak cloudSync] _ in
            Task { @MainActor in
                await cloudSync?.syncNow()
            }
        }
        panel.onOpenSettings = { [weak settingsWindow] in
            settingsWindow?.show()
        }
        toolWindows.onOpenSettings = { [weak settingsWindow] in settingsWindow?.showTranslation() }
        quickAIWindows.onOpenSettings = { [weak settingsWindow] in settingsWindow?.showTranslation() }
        self.settingsWindow = settingsWindow
        selectionTranslation.onOpenSettings = { [weak settingsWindow] in settingsWindow?.showTranslation() }
        selectionTranslation.onEditSource = { [weak toolWindows] text in
            toolWindows?.openTool(ToolOpenRequest(kind: .translation, input: text))
        }
        self.coordinator = coordinator
        self.panel = panel
        bindSearchRefresh(panel: panel, toolWindows: toolWindows, registry: registry)

        let menuBar = MenuBarController()
        menuBar.updates = updateController
        menuBar.onOpenLauncher = { [weak panel] in panel?.toggle() }
        menuBar.onOpenGuide = { [weak settingsWindow] in settingsWindow?.showGuide() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.hotKeyDisplay = HotKeyFormatter.displayString(for: settings.hotKey)
        menuBar.install()
        self.menuBar = menuBar

        hotKeyCoordinator.start(
            onToggle: { [weak panel] in panel?.toggle() },
            onDisplayChanged: { [weak menuBar, weak panel] display in
                menuBar?.hotKeyDisplay = display
                panel?.updateHotKeyDisplay(display)
            }
        )

        Task {
            await appIndex.scan()
            panel.refreshSearch()
        }

        handleLaunchArguments(toolWindows: toolWindows, noteWindows: noteWindows, panel: panel, settingsWindow: settingsWindow)
    }

    var needsTerminationPreparation: Bool { noteWindows?.hasOpenWindows ?? false }

    func prepareToTerminate() async -> Bool {
        await termination.run()
    }

    func shutdown() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        cloudSync?.stop()
        appIndex.stopMonitoring()
        searchRefreshCancellables.removeAll()
        selectionTranslation?.shutdown()
        hotKeyCoordinator?.stop()
        pluginManager?.shutdownSync()
        usage.flush()
        noteWindows?.shutdown()
        quickAIWindows?.shutdown()
        toolWindows?.shutdown()
    }

    private func bindSearchRefresh(panel: LauncherPanelController, toolWindows: ToolWindowManager, registry: ToolRegistry) {
        observeRefresh(settings.$enabledProviderIDs, panel: panel)
        observeRefresh(registry.$pluginProviders, panel: panel)
        observeRefresh(pluginSettings.$disabledPluginIDs, panel: panel)
        observeRefresh(notes.$notes, panel: panel)
        observeRefresh(websites.$configuration, panel: panel)
        observeRefresh(searchEngines.$configuration, panel: panel)
        observeRefresh(appIndex.$apps, panel: panel)
        observeRefresh(settings.$applicationSortOrder, panel: panel)
        toolWindows.onDocumentsChanged = { [weak panel] in panel?.refreshSearch() }
    }

    private func observeRefresh<P: Publisher>(_ publisher: P, panel: LauncherPanelController) where P.Failure == Never {
        publisher.dropFirst().sink { [weak panel] _ in
            DispatchQueue.main.async { panel?.refreshSearch() }
        }
        .store(in: &searchRefreshCancellables)
    }

    private func handleLaunchArguments(
        toolWindows: ToolWindowManager,
        noteWindows: LocalNoteWindowManager,
        panel: LauncherPanelController,
        settingsWindow: SettingsWindowController
    ) {
        if let flag = CommandLine.arguments.firstIndex(of: "--tool"),
           CommandLine.arguments.indices.contains(flag + 1),
           let kind = ToolKind(rawValue: CommandLine.arguments[flag + 1]) {
            toolWindows.openTool(ToolOpenRequest(kind: kind))
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
