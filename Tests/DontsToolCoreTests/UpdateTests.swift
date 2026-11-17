import Foundation
import Testing
@testable import DontsToolCore

@Suite("更新版本与安装保护")
@MainActor
struct UpdateTests {
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
}
