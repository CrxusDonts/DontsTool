import AppKit
import Combine
import DontsToolCore
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableUpdateVersion: String?
    @Published private(set) var visibleLauncherUpdateVersion: String?
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            guard oldValue != automaticallyChecksForUpdates else { return }
            standard?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    private var standard: SPUStandardUpdaterController!
    private let currentVersion: String
    private let isUpdaterStarted: Bool
    private let dailyPolicy: DailyUpdateCheckPolicy
    private let customBackgroundCheckRunner: (@MainActor () -> Void)?
    private let installation: UpdateInstallationGate
    private var observations: Set<AnyCancellable> = []
    private let resumeAfterFailure: @MainActor () async -> Void
    private var preparedInstallation = false
    @Published private var recovering = false
    var sparkleUpdater: SPUUpdater { standard.updater }

    init(
        currentVersion: String = AppInfo.version,
        startUpdater: Bool = true,
        defaults: UserDefaults = .standard,
        backgroundCheckRunner: (@MainActor () -> Void)? = nil,
        resumeAfterFailure: @escaping @MainActor () async -> Void = {},
        prepareToInstall: @escaping @MainActor () async -> Bool
    ) {
        self.currentVersion = currentVersion
        self.isUpdaterStarted = startUpdater
        self.dailyPolicy = DailyUpdateCheckPolicy(defaults: defaults)
        self.customBackgroundCheckRunner = backgroundCheckRunner
        self.resumeAfterFailure = resumeAfterFailure
        installation = UpdateInstallationGate(prepare: prepareToInstall)
        super.init()
        standard = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        standard.updater.sendsSystemProfile = false
        standard.updater.automaticallyDownloadsUpdates = false
        standard.updater.publisher(for: \.canCheckForUpdates)
            .combineLatest(installation.$hasPendingInstallation, installation.$isPreparing, $recovering)
            .sink { [weak self] available, pending, preparing, recovering in
                self?.canCheckForUpdates = (available || pending) && !preparing && !recovering
            }.store(in: &observations)
        standard.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] enabled in self?.automaticallyChecksForUpdates = enabled }
            .store(in: &observations)
        if startUpdater { standard.startUpdater() }
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheckForUpdates else { return }
        if installation.hasPendingInstallation {
            Task { await installation.resume() }
        } else if canCheckForUpdates {
            NSApp.activate(ignoringOtherApps: true)
            standard.checkForUpdates(sender)
        }
    }

    @discardableResult
    func checkForUpdatesOnLauncherOpenIfNeeded(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard dailyPolicy.shouldTriggerDailyCheck(
            now: now,
            calendar: calendar,
            automaticallyChecks: automaticallyChecksForUpdates,
            hasAvailableUpdate: availableUpdateVersion != nil
        ) else {
            return false
        }
        guard !installation.hasPendingInstallation, !installation.isPreparing, !recovering,
              !standard.updater.sessionInProgress else {
            return false
        }
        if customBackgroundCheckRunner == nil {
            guard isUpdaterStarted, canCheckForUpdates else {
                return false
            }
        }
        dailyPolicy.recordCheckAttempt(now: now, calendar: calendar)
        if let customBackgroundCheckRunner {
            customBackgroundCheckRunner()
        } else {
            standard.updater.checkForUpdatesInBackground()
        }
        return true
    }

    func dismissAvailableUpdateBanner() {
        guard let version = availableUpdateVersion else { return }
        dailyPolicy.dismissVersion(version)
        visibleLauncherUpdateVersion = nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let candidateVersion = update.displayVersionString
        MainActor.assumeIsolated {
            handleScheduledUpdateReminder(
                handleShowingUpdate: handleShowingUpdate,
                candidateVersion: candidateVersion
            )
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            availableUpdateVersion = nil
            visibleLauncherUpdateVersion = nil
        }
    }

    func handleScheduledUpdateReminder(handleShowingUpdate: Bool, candidateVersion: String) {
        guard !handleShowingUpdate, UpdateVersion.isNewer(candidateVersion, than: currentVersion) else {
            return
        }
        availableUpdateVersion = candidateVersion
        visibleLauncherUpdateVersion = dailyPolicy.isVersionDismissed(candidateVersion) ? nil : candidateVersion
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard UpdateVersion.isNewer(updateItem.displayVersionString, than: currentVersion) else {
            throw NSError(domain: "DontsTool.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "当前已是最新稳定版本，无需安装同版或更旧版本。"])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        preparedInstallation = true
        installation.postpone { installHandler() }
        Task { await installation.resume() }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard preparedInstallation else { return }
        preparedInstallation = false
        recovering = true
        Task {
            await installation.cancel()
            await resumeAfterFailure()
            recovering = false
        }
    }
}
