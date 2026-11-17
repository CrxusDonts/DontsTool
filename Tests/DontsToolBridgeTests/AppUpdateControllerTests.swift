import AppKit
import DontsToolCore
import Sparkle
import Testing

@Suite("原生更新协调", .serialized)
@MainActor
struct AppUpdateControllerTests {
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
}
