import Foundation
import Testing
import Translation
@testable import DontsToolCore

@Suite("System translation", .serialized)
@MainActor
struct SystemTranslationServiceTests {
    @Test func installedPairUsesIdentifiedSourceAndRequestedTarget() async throws {
        let backend = SystemBackendFixture()
        let service = SystemTranslationService(backend: backend, identifyLanguage: { _ in "en" })
        #expect(service.isConfigured)
        #expect(try await service.translate(" selected text ", target: "zh-Hans") == "译文")
        #expect(backend.checkedPairs == ["en→zh-Hans"])
        #expect(backend.sessions.first?.input == "selected text")
    }

    @Test func supportedButMissingPairRequestsLanguageDownloadWithoutCreatingSession() async throws {
        let backend = SystemBackendFixture()
        backend.status = .supported
        let service = SystemTranslationService(backend: backend, identifyLanguage: { _ in "en" })
        do {
            _ = try await service.translate("text", target: "zh-Hans")
            Issue.record("An uninstalled pair cannot translate")
        } catch {
            #expect(error.localizedDescription.contains("请先下载翻译语言包"))
        }
        #expect(backend.sessions.isEmpty)
    }

    @Test func unsupportedPairHasExplicitFailureWithoutCreatingSession() async throws {
        let backend = SystemBackendFixture()
        backend.status = .unsupported
        let service = SystemTranslationService(backend: backend, identifyLanguage: { _ in "en" })
        do {
            _ = try await service.translate("text", target: "zz")
            Issue.record("An unsupported pair cannot translate")
        } catch { #expect(error.localizedDescription.contains("不支持")) }
        #expect(backend.sessions.isEmpty)
    }

    @Test func unrecognizedSourceDoesNotCreateSession() async throws {
        let backend = SystemBackendFixture()
        let service = SystemTranslationService(backend: backend, identifyLanguage: { _ in nil })
        do {
            _ = try await service.translate("12345", target: "zh-Hans")
            Issue.record("Source recognition must fail explicitly")
        } catch { #expect(error.localizedDescription.contains("识别")) }
        #expect(backend.checkedPairs.isEmpty)
        #expect(backend.sessions.isEmpty)
    }

    @Test func emptyInputDoesNotInspectLanguageOrCreateSession() async throws {
        let backend = SystemBackendFixture()
        let service = SystemTranslationService(backend: backend, identifyLanguage: { _ in
            Issue.record("Empty input cannot be passed to language detection")
            return "en"
        })
        do {
            _ = try await service.translate("  \n", target: "zh-Hans")
            Issue.record("Empty input must fail explicitly")
        } catch { #expect(error.localizedDescription.contains("为空")) }
        #expect(backend.checkedPairs.isEmpty)
        #expect(backend.sessions.isEmpty)
    }

    @Test func matchingLanguageReturnsSourceWithoutCallingTranslationBackend() async throws {
        let backend = SystemBackendFixture()
        let service = SystemTranslationService(backend: backend, identifyLanguage: { _ in "en" })
        #expect(try await service.translate("already English", target: "en") == "already English")
        #expect(backend.checkedPairs.isEmpty)
        #expect(backend.sessions.isEmpty)
    }

    @Test func cancellingOneRequestCancelsOnlyItsSessionAndRejectsLateOutput() async throws {
        let backend = SystemBackendFixture()
        backend.delaySessions = true
        let service = SystemTranslationService(backend: backend, identifyLanguage: { _ in "en" })
        let first = Task { try await service.translate("first", target: "zh-Hans") }
        try await until { backend.sessions.count == 1 && backend.sessions[0].continuation != nil }
        let second = Task { try await service.translate("second", target: "zh-Hans") }
        try await until { backend.sessions.count == 2 && backend.sessions[1].continuation != nil }
        first.cancel()
        try await until { backend.sessions[0].cancelled }
        #expect(!backend.sessions[1].cancelled)
        backend.sessions[0].continuation?.resume(returning: "late cancelled output")
        do { _ = try await first.value; Issue.record("Cancelled request must reject late output") }
        catch { #expect(error is CancellationError) }
        backend.sessions[1].continuation?.resume(returning: "second translation")
        #expect(try await second.value == "second translation")
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SystemTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum SystemTestError: Error { case timeout }

@MainActor
private final class SystemBackendFixture: SystemTranslationBackend {
    var status = LanguageAvailability.Status.installed
    var checkedPairs: [String] = []
    var sessions: [SystemSessionFixture] = []
    var delaySessions = false
    func availability(source: String, target: String) async -> LanguageAvailability.Status {
        checkedPairs.append("\(source)→\(target)")
        return status
    }
    func session(source: String, target: String) -> any SystemTranslationSession {
        let session = SystemSessionFixture(delay: delaySessions)
        sessions.append(session)
        return session
    }
}

@MainActor
private final class SystemSessionFixture: SystemTranslationSession {
    let delay: Bool
    var input: String?
    var cancelled = false
    var continuation: CheckedContinuation<String, Never>?
    init(delay: Bool) { self.delay = delay }
    func translate(_ text: String) async throws -> String {
        input = text
        if delay { return await withCheckedContinuation { continuation = $0 } }
        return "译文"
    }
    func cancel() { cancelled = true }
}
