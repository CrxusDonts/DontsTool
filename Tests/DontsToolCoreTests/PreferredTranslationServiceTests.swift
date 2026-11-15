import Foundation
import Testing
@testable import DontsToolCore

@Suite("Translation provider preference")
@MainActor
struct PreferredTranslationServiceTests {
    @Test func missingAPIUsesSystemAndCompleteAPIWinsDynamically() async throws {
        let remote = PreferredTranslatorFixture(configured: false, result: "remote")
        let system = PreferredTranslatorFixture(configured: true, result: "system")
        let service = PreferredTranslationService(remote: remote, system: system)
        #expect(service.isConfigured)
        #expect(try await service.translate("text", target: "zh-Hans") == "system")
        remote.isConfigured = true
        #expect(try await service.translate("text", target: "en") == "remote")
        remote.isConfigured = false
        #expect(try await service.translate("text", target: "ja") == "system")
        #expect(remote.targets == ["en"])
        #expect(system.targets == ["zh-Hans", "ja"])
    }

    @Test func remoteFailureAndCancellationNeverFallbackToSystem() async throws {
        for error in [ActionError.translationFailed("remote failure") as any Error, CancellationError()] {
            let remote = PreferredTranslatorFixture(configured: true, result: "remote")
            let system = PreferredTranslatorFixture(configured: true, result: "system")
            remote.error = error
            let service = PreferredTranslationService(remote: remote, system: system)
            do {
                _ = try await service.translate("text", target: "zh-Hans")
                Issue.record("Remote error must reach caller")
            } catch let received {
                if error is CancellationError { #expect(received is CancellationError) }
                else { #expect(received.localizedDescription == error.localizedDescription) }
            }
            #expect(remote.targets == ["zh-Hans"])
            #expect(system.targets.isEmpty)
        }
    }
}

@MainActor
private final class PreferredTranslatorFixture: TranslationServicing {
    var isConfigured: Bool
    let result: String
    var error: (any Error)?
    var targets: [String] = []
    init(configured: Bool, result: String) { isConfigured = configured; self.result = result }
    func translate(_ text: String, target: String) async throws -> String {
        targets.append(target)
        if let error { throw error }
        return result
    }
}
