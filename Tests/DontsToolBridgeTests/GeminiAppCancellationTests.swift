import Foundation
import Testing

@Suite("Gemini Escape monitoring lifecycle")
@MainActor
struct GeminiAppCancellationTests {
    @Test func listeningBeginsOnlyForAHandoffAndEndsOnFinish() {
        let monitor = GeminiEscapeMonitorFixture()
        let lifecycle = GeminiHandoffCancellation(monitor: monitor)
        let cancellation = lifecycle.prepare()
        #expect(monitor.starts == 0)
        #expect(!cancellation.isCancelled)
        lifecycle.begin()
        lifecycle.begin()
        #expect(monitor.starts == 1)
        monitor.escape?()
        #expect(cancellation.isCancelled)
        lifecycle.finish()
        #expect(monitor.stops == 1)
        #expect(monitor.escape == nil)
    }

    @Test func finishingCancelsInflightWorkAndTheNextHandoffGetsAFreshFlag() {
        let monitor = GeminiEscapeMonitorFixture()
        let lifecycle = GeminiHandoffCancellation(monitor: monitor)
        let previous = lifecycle.prepare()
        lifecycle.begin()
        let staleCallback = monitor.escape
        lifecycle.finish()
        #expect(previous.isCancelled)
        let current = lifecycle.prepare()
        #expect(!current.isCancelled)
        staleCallback?()
        #expect(!current.isCancelled)
        lifecycle.begin()
        monitor.escape?()
        #expect(current.isCancelled)
        lifecycle.finish()
        #expect(monitor.stops == 2)
    }
}

@MainActor
private final class GeminiEscapeMonitorFixture: GeminiEscapeMonitoring {
    var starts = 0
    var stops = 0
    var escape: (@Sendable () -> Void)?
    func start(_ onEscape: @escaping @Sendable () -> Void) { starts += 1; escape = onEscape }
    func stop() { stops += 1; escape = nil }
}
