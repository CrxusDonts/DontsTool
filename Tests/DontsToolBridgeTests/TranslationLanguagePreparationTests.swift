import Foundation
import Testing

@Suite("Translation language preparation generations", .serialized)
@MainActor
struct TranslationLanguagePreparationTests {
    @Test func lateOldCallbackCannotStartDownloadOrCompleteNewPreparation() async throws {
        let model = TranslationLanguagePreparation(target: "zh-Hans")
        #expect(model.request == nil)
        model.prepare()
        let oldID = try #require(model.request?.id)
        model.cancel()
        model.prepare()
        let newID = try #require(model.request?.id)
        let preparingStatus = model.status
        let staleSession = PreparationSessionFixture(suspended: false)
        await model.run(session: staleSession, requestID: oldID)
        #expect(model.request?.id == newID)
        #expect(model.isPreparing)
        #expect(!model.isReady)
        #expect(model.status == preparingStatus)
        #expect(staleSession.prepareCount == 0)
        #expect(staleSession.cancelCount == 1)
        model.cancel()
        #expect(staleSession.cancelCount == 1)
    }

    @Test func staleRunningSessionCannotClearOrCancelNewSession() async throws {
        let model = TranslationLanguagePreparation(target: "en")
        model.prepare()
        let oldID = try #require(model.request?.id)
        let oldSession = PreparationSessionFixture(suspended: true)
        let oldTask = Task { await model.run(session: oldSession, requestID: oldID) }
        try await until { oldSession.continuation != nil }
        model.cancel()
        #expect(oldSession.cancelCount == 1)
        model.prepare()
        let newID = try #require(model.request?.id)
        let newSession = PreparationSessionFixture(suspended: true)
        let newTask = Task { await model.run(session: newSession, requestID: newID) }
        try await until { newSession.continuation != nil }
        let preparingStatus = model.status
        oldTask.cancel()
        oldSession.continuation?.resume(throwing: CancellationError())
        await oldTask.value
        #expect(model.request?.id == newID)
        #expect(model.isPreparing)
        #expect(!model.isReady)
        #expect(model.status == preparingStatus)
        #expect(newSession.cancelCount == 0)
        model.cancel()
        #expect(newSession.cancelCount == 1)
        #expect(oldSession.cancelCount == 1)
        newSession.continuation?.resume(returning: ())
        await newTask.value
        #expect(model.request == nil)
        #expect(!model.isPreparing)
        #expect(!model.isReady)
    }

    @Test func matchingPreparationCanPublishReadiness() async throws {
        let model = TranslationLanguagePreparation(target: "zh-Hans")
        model.prepare()
        let id = try #require(model.request?.id)
        let session = PreparationSessionFixture(suspended: false)
        await model.run(session: session, requestID: id)
        #expect(model.isReady)
        #expect(!model.isPreparing)
        #expect(session.prepareCount == 1)
        #expect(session.cancelCount == 0)
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw PreparationFixtureError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum PreparationFixtureError: Error { case timeout }

@MainActor
private final class PreparationSessionFixture: TranslationLanguagePreparingSession {
    let suspended: Bool
    var prepareCount = 0
    var cancelCount = 0
    var continuation: CheckedContinuation<Void, any Error>?
    init(suspended: Bool) { self.suspended = suspended }
    func prepareTranslation() async throws {
        prepareCount += 1
        if suspended { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    var isReady: Bool { get async { true } }
    func cancel() { cancelCount += 1 }
}
