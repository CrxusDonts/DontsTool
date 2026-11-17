import AppKit
import Combine
import DontsToolCore
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, NSMenuItemValidation {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            guard oldValue != automaticallyChecksForUpdates else { return }
            standard?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    private var standard: SPUStandardUpdaterController!
    private let currentVersion: String
    private let installation: UpdateInstallationGate
    private var observations: Set<AnyCancellable> = []
    var sparkleUpdater: SPUUpdater { standard.updater }

    init(currentVersion: String = AppInfo.version, startUpdater: Bool = true,
         prepareToInstall: @escaping @MainActor () async -> Bool) {
        self.currentVersion = currentVersion
        installation = UpdateInstallationGate(prepare: prepareToInstall)
        super.init()
        standard = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        standard.updater.sendsSystemProfile = false
        standard.updater.automaticallyDownloadsUpdates = false
        standard.updater.publisher(for: \.canCheckForUpdates)
            .combineLatest(installation.$hasPendingInstallation, installation.$isPreparing)
            .sink { [weak self] available, pending, preparing in
                self?.canCheckForUpdates = (available || pending) && !preparing
            }.store(in: &observations)
        standard.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] enabled in self?.automaticallyChecksForUpdates = enabled }
            .store(in: &observations)
        if startUpdater { standard.startUpdater() }
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        if installation.hasPendingInstallation {
            Task { await installation.resume() }
        } else if canCheckForUpdates {
            NSApp.activate(ignoringOtherApps: true)
            standard.checkForUpdates(sender)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard UpdateVersion.isNewer(updateItem.displayVersionString, than: currentVersion) else {
            throw NSError(domain: "DontsTool.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "当前已是最新稳定版本，无需安装同版或更旧版本。"])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        installation.postpone { installHandler() }
        Task { await installation.resume() }
        return true
    }
}
