import AppKit
import DontsToolCore
import Sparkle
import Testing

@Suite("原生更新协调", .serialized)
@MainActor
struct AppUpdateControllerTests {
    @Test(arguments: [false, true])
    func abortedPreparedUpdateRestoresEditorsAndDropsItsInstallCallback(approved: Bool) async throws {
        _ = NSApplication.shared
        var recoveries = 0
        let controller = AppUpdateController(currentVersion: "0.2.6", startUpdater: false,
                                            resumeAfterFailure: { recoveries += 1 }, prepareToInstall: { approved })
        let item = try #require(SUAppcastItem(dictionary: [
            "sparkle:version": "99", "sparkle:shortVersionString": "0.2.7",
            "enclosure": ["url": "https://example.com/update.zip", "length": "100"]
        ]))
        var installs = 0
        _ = controller.updater(controller.sparkleUpdater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installs += 1 })
        for _ in 0..<20 { await Task.yield() }
        controller.updater(controller.sparkleUpdater, didAbortWithError: NSError(domain: "Fixture", code: 1))
        for _ in 0..<20 { await Task.yield() }
        #expect(recoveries == 1)
        let completedBeforeAbort = installs
        controller.checkForUpdates(nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(installs == completedBeforeAbort)
    }
    @Test func delegateRejectsDowngradeEvenWhenCandidateBuildIsHigher() throws {
        _ = NSApplication.shared
        let controller = AppUpdateController(currentVersion: "0.2.7", startUpdater: false, prepareToInstall: { true })
        let item = try #require(SUAppcastItem(dictionary: [
            "sparkle:version": "99999", "sparkle:shortVersionString": "0.2.6",
            "enclosure": ["url": "https://example.com/update.zip", "length": "100"]
        ]))
        #expect(throws: (any Error).self) {
            try controller.updater(controller.sparkleUpdater, shouldProceedWithUpdate: item, updateCheck: .updates)
        }
    }

    @Test func postponedInstallationRespectsSaveVetoAndAllowsMenuRetry() async throws {
        _ = NSApplication.shared
        var approved = false
        var installs = 0
        let controller = AppUpdateController(currentVersion: "0.2.6", startUpdater: false, prepareToInstall: { approved })
        let item = try #require(SUAppcastItem(dictionary: [
            "sparkle:version": "99", "sparkle:shortVersionString": "0.2.7",
            "enclosure": ["url": "https://example.com/update.zip", "length": "100"]
        ]))
        #expect(controller.updater(controller.sparkleUpdater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installs += 1 }))
        for _ in 0..<20 { await Task.yield() }
        #expect(installs == 0)
        #expect(controller.canCheckForUpdates)
        approved = true
        controller.checkForUpdates(nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(installs == 1)
    }

    @Test func gentleReminderDelegatesBackgroundUpdatesWithoutModalInterruption() throws {
        _ = NSApplication.shared
        let suiteName = "dontstool.bridge.update.gentle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = AppUpdateController(
            currentVersion: "0.4.0",
            startUpdater: false,
            defaults: defaults,
            prepareToInstall: { true }
        )
        let newerItem = try #require(SUAppcastItem(dictionary: [
            "sparkle:version": "10", "sparkle:shortVersionString": "0.4.1",
            "enclosure": ["url": "https://example.com/update.zip", "length": "100"]
        ]))

        #expect(controller.supportsGentleScheduledUpdateReminders)
        #expect(!controller.standardUserDriverShouldHandleShowingScheduledUpdate(newerItem, andInImmediateFocus: true))
        #expect(!controller.standardUserDriverShouldHandleShowingScheduledUpdate(newerItem, andInImmediateFocus: false))

        controller.handleScheduledUpdateReminder(handleShowingUpdate: false, candidateVersion: "0.4.0")
        #expect(controller.availableUpdateVersion == nil)
        #expect(controller.visibleLauncherUpdateVersion == nil)

        controller.handleScheduledUpdateReminder(handleShowingUpdate: false, candidateVersion: "0.3.9")
        #expect(controller.availableUpdateVersion == nil)

        controller.handleScheduledUpdateReminder(handleShowingUpdate: true, candidateVersion: "0.4.1")
        #expect(controller.availableUpdateVersion == nil)

        controller.handleScheduledUpdateReminder(handleShowingUpdate: false, candidateVersion: "0.4.1")
        #expect(controller.availableUpdateVersion == "0.4.1")
        #expect(controller.visibleLauncherUpdateVersion == "0.4.1")

        controller.dismissAvailableUpdateBanner()
        #expect(controller.availableUpdateVersion == "0.4.1")
        #expect(controller.visibleLauncherUpdateVersion == nil)

        let reloaded = AppUpdateController(
            currentVersion: "0.4.0",
            startUpdater: false,
            defaults: defaults,
            prepareToInstall: { true }
        )
        reloaded.handleScheduledUpdateReminder(handleShowingUpdate: false, candidateVersion: "0.4.1")
        #expect(reloaded.availableUpdateVersion == "0.4.1")
        #expect(reloaded.visibleLauncherUpdateVersion == nil)

        reloaded.handleScheduledUpdateReminder(handleShowingUpdate: false, candidateVersion: "0.4.2")
        #expect(reloaded.availableUpdateVersion == "0.4.2")
        #expect(reloaded.visibleLauncherUpdateVersion == "0.4.2")

        reloaded.standardUserDriverWillFinishUpdateSession()
        #expect(reloaded.availableUpdateVersion == nil)
        #expect(reloaded.visibleLauncherUpdateVersion == nil)
    }

    @Test func launcherOpenTriggersBackgroundCheckOncePerDayWhenEnabled() throws {
        _ = NSApplication.shared
        let suiteName = "dontstool.bridge.update.daily.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let day1Morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9)))
        let day1Afternoon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 15)))
        let day2Morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9)))

        var checks = 0
        let controller = AppUpdateController(
            currentVersion: "0.4.0",
            startUpdater: false,
            defaults: defaults,
            backgroundCheckRunner: { checks += 1 },
            prepareToInstall: { true }
        )
        controller.automaticallyChecksForUpdates = true

        #expect(controller.checkForUpdatesOnLauncherOpenIfNeeded(now: day1Morning, calendar: calendar))
        #expect(checks == 1)

        #expect(!controller.checkForUpdatesOnLauncherOpenIfNeeded(now: day1Afternoon, calendar: calendar))
        #expect(checks == 1)

        controller.automaticallyChecksForUpdates = false
        #expect(!controller.checkForUpdatesOnLauncherOpenIfNeeded(now: day2Morning, calendar: calendar))
        #expect(checks == 1)

        controller.automaticallyChecksForUpdates = true
        controller.handleScheduledUpdateReminder(handleShowingUpdate: false, candidateVersion: "0.4.1")
        #expect(!controller.checkForUpdatesOnLauncherOpenIfNeeded(now: day2Morning, calendar: calendar))
        #expect(checks == 1)

        controller.standardUserDriverWillFinishUpdateSession()
        #expect(controller.checkForUpdatesOnLauncherOpenIfNeeded(now: day2Morning, calendar: calendar))
        #expect(checks == 2)
    }

    @Test func panelModelAndMenuBarReflectAvailableUpdateVersion() throws {
        _ = NSApplication.shared
        let suiteName = "dontstool.bridge.update.menubar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = AppUpdateController(
            currentVersion: "0.4.0",
            startUpdater: false,
            defaults: defaults,
            prepareToInstall: { true }
        )
        let menuBar = MenuBarController()
        menuBar.updates = controller
        menuBar.install()

        let registry = ToolRegistry(providers: [])
        let model = LauncherPanelModel(coordinator: SearchCoordinator(registry: registry), hotKeyDisplay: "⌥Space")
        model.updateAvailableUpdateVersion("0.4.1")
        #expect(model.availableUpdateVersion == "0.4.1")

        controller.handleScheduledUpdateReminder(handleShowingUpdate: false, candidateVersion: "0.4.1")
        #expect(controller.availableUpdateVersion == "0.4.1")
        controller.standardUserDriverWillFinishUpdateSession()
        #expect(controller.availableUpdateVersion == nil)
    }
}
