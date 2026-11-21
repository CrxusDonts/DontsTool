import Foundation
import Testing
@testable import DontsToolCore

@Suite("更新版本与安装保护")
@MainActor
struct UpdateTests {
    @Test func abortWhilePreparingInvalidatesThePendingInstallation() async {
        var completion: CheckedContinuation<Bool, Never>?
        var installs = 0
        let gate = UpdateInstallationGate(prepare: { await withCheckedContinuation { completion = $0 } })
        gate.postpone { installs += 1 }
        let attempt = Task { await gate.resume() }
        while completion == nil { await Task.yield() }
        let abort = Task { await gate.cancel() }
        while gate.hasPendingInstallation { await Task.yield() }
        completion?.resume(returning: true)
        await attempt.value
        await abort.value
        await gate.resume()
        #expect(installs == 0)
        #expect(!gate.hasPendingInstallation)
    }

    @Test func updateAndCommandQShareTheInFlightDocumentPreparation() async {
        var calls = 0
        var completion: CheckedContinuation<Bool, Never>?
        let preparation = TerminationPreparation(prepare: {
            calls += 1
            return await withCheckedContinuation { completion = $0 }
        })
        let update = Task { await preparation.run() }
        while completion == nil { await Task.yield() }
        let quit = Task { await preparation.run() }
        for _ in 0..<10 { await Task.yield() }
        #expect(calls == 1)
        completion?.resume(returning: true)
        #expect(await update.value)
        #expect(await quit.value)
    }
    @Test(arguments: [
        ("0.2.7", "0.2.6", true),
        ("0.10.0", "0.9.9", true),
        ("1.0.0", "0.99.99", true),
        ("0.2.6", "0.2.6", false),
        ("0.2.5", "0.2.6", false),
        ("0.2.7-rc.1", "0.2.6", false),
        ("0.2.7+build.2", "0.2.6", false),
        ("v0.2.7", "0.2.6", false),
        ("00.2.7", "0.2.6", false),
        ("0.2", "0.2.6", false),
        ("0.2.7", "invalid", false),
        ("999999999999999999999.2.7", "0.2.6", false)
    ])
    func onlyNewerStableShortVersionsAreEligible(candidate: String, current: String, expected: Bool) {
        #expect(UpdateVersion.isNewer(candidate, than: current) == expected)
    }

    @Test func cancelledDocumentSaveKeepsInstallationPendingUntilExplicitRetry() async {
        var approved = false
        var saves = 0
        var installations = 0
        let gate = UpdateInstallationGate(prepare: { saves += 1; return approved })
        gate.postpone { installations += 1 }
        await gate.resume()
        #expect(saves == 1)
        #expect(installations == 0)
        #expect(gate.hasPendingInstallation)
        #expect(!gate.isPreparing)

        approved = true
        await gate.resume()
        await gate.resume()
        #expect(saves == 2)
        #expect(installations == 1)
        #expect(!gate.hasPendingInstallation)
    }

    @Test func concurrentInstallRequestsSaveAndInstallOnlyOnce() async {
        var saves = 0
        var installations = 0
        var completion: CheckedContinuation<Bool, Never>?
        let gate = UpdateInstallationGate(prepare: {
            saves += 1
            return await withCheckedContinuation { completion = $0 }
        })
        gate.postpone { installations += 1 }
        let first = Task { await gate.resume() }
        while completion == nil { await Task.yield() }
        await gate.resume()
        #expect(saves == 1)
        #expect(gate.isPreparing)
        #expect(installations == 0)
        completion?.resume(returning: true)
        await first.value
        #expect(installations == 1)
        #expect(!gate.isPreparing)
    }

    @Test func dailyPolicyAllowsFirstOpenAndThrottlesSameDayChecks() throws {
        let suiteName = "dontstool.update.policy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let day1Morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9)))
        let day1Evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 21)))
        let day2Morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 8)))

        let policy = DailyUpdateCheckPolicy(defaults: defaults)
        #expect(policy.shouldTriggerDailyCheck(
            now: day1Morning,
            calendar: calendar,
            automaticallyChecks: true,
            hasAvailableUpdate: false
        ))

        policy.recordCheckAttempt(now: day1Morning, calendar: calendar)
        #expect(!policy.shouldTriggerDailyCheck(
            now: day1Evening,
            calendar: calendar,
            automaticallyChecks: true,
            hasAvailableUpdate: false
        ))
        #expect(!policy.shouldTriggerDailyCheck(
            now: day2Morning,
            calendar: calendar,
            automaticallyChecks: false,
            hasAvailableUpdate: false
        ))
        #expect(!policy.shouldTriggerDailyCheck(
            now: day2Morning,
            calendar: calendar,
            automaticallyChecks: true,
            hasAvailableUpdate: true
        ))
        #expect(policy.shouldTriggerDailyCheck(
            now: day2Morning,
            calendar: calendar,
            automaticallyChecks: true,
            hasAvailableUpdate: false
        ))
    }

    @Test func dailyPolicyPersistsDismissedVersionAndResumesHigherVersions() throws {
        let suiteName = "dontstool.update.dismiss.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let policy = DailyUpdateCheckPolicy(defaults: defaults)
        #expect(!policy.isVersionDismissed("0.4.2"))
        policy.dismissVersion("0.4.2")
        #expect(policy.isVersionDismissed("0.4.2"))

        let reloaded = DailyUpdateCheckPolicy(defaults: defaults)
        #expect(reloaded.isVersionDismissed("0.4.2"))
        #expect(!reloaded.isVersionDismissed("0.4.3"))

        reloaded.clearDismissedVersion()
        #expect(!reloaded.isVersionDismissed("0.4.2"))
    }
}
