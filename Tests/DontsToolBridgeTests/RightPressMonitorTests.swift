import AppKit
import DontsToolCore
import Testing

@Suite("Right press event routing", .serialized)
@MainActor
struct RightPressMonitorTests {
    @Test func shortClickDoesNotReadOrTranslateAndRestoresDownBeforeUp() async throws {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await Task.yield()
        #expect(fixture.reads == 0)
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed == [.rightMouseDown])
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 0)
        #expect(fixture.translations == 0)
        monitor.stop()
    }

    @Test func validHoldReadsAfterDeadlineAndSurvivesPhysicalReleaseWhileReading() async throws {
        let fixture = RightPressFixture()
        fixture.reading = SelectionReading(text: "browser selection", diagnostic: "已读取选区")
        let monitor = fixture.monitor()
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        #expect(fixture.reads == 0)
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        #expect(fixture.readingCards == 1)
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        fixture.read.release()
        await settle()
        #expect(fixture.translations == 1)
        #expect(fixture.replayed.isEmpty)
        monitor.stop()
    }

    @Test func failedReadShowsFailureInsteadOfSilentlyCancelling() async throws {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        await settle()
        fixture.now = 2
        fixture.hold.release()
        await settle()
        fixture.read.release()
        await settle()
        #expect(fixture.failures == ["应用未提供选中文字"])
        #expect(fixture.translations == 0)
        monitor.stop()
    }

    @Test func physicalReleaseBeforeDelayedDeadlineNeverReads() async throws {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        await settle()
        fixture.now = 3
        fixture.buttonDown = false
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 0)
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed == [.rightMouseDown])
        monitor.stop()
    }

    @Test func changedWindowConsumesSuppressedUpWithoutReplayingIntoNewTarget() async throws {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        fixture.window = 9
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed.isEmpty)
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 0)
        monitor.stop()
    }

    @Test func movementRestoresNativeDragAndCancelsReading() async throws {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        #expect(monitor.handle(.rightMouseDragged, event: fixture.event(.rightMouseDragged, x: 20), proxy: nil))
        #expect(fixture.replayed == [.rightMouseDown])
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 0)
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        monitor.stop()
    }

    @Test func sourceApplicationChangePreventsACommittedReadFromSendingTranslation() async throws {
        let fixture = RightPressFixture()
        fixture.reading = SelectionReading(text: "selection", diagnostic: "已读取选区")
        let monitor = fixture.monitor()
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        await settle()
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        fixture.frontmost = 99
        fixture.read.release()
        await settle()
        #expect(fixture.translations == 0)
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed.isEmpty)
        monitor.stop()
    }

    @Test func readDeadlineShowsFailureAndIgnoresLateSelection() async throws {
        let fixture = RightPressFixture()
        fixture.reading = SelectionReading(text: "late selection", diagnostic: "已读取选区")
        let monitor = fixture.monitor()
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        await settle()
        fixture.now = 2
        fixture.hold.release()
        await settle()
        fixture.timeout.release()
        await settle()
        #expect(fixture.failures.count == 1)
        #expect(fixture.failures.first?.contains("超时") == true)
        fixture.read.release()
        await settle()
        #expect(fixture.translations == 0)
        monitor.stop()
    }

    @Test func cancellingPendingReadRejectsLateTextAndStillConsumesMatchingMouseUp() async throws {
        let fixture = RightPressFixture()
        fixture.reading = SelectionReading(text: "closed selection", diagnostic: "已读取选区")
        let monitor = fixture.monitor()
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        await settle()
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        monitor.cancelPendingReading()
        fixture.read.release()
        await settle()
        #expect(fixture.translations == 0)
        #expect(fixture.failures.isEmpty)
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed.isEmpty)
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        monitor.stop()
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor
private final class RightPressFixture {
    let hold = PressGate()
    let read = PressGate()
    let timeout = PressGate()
    var now: TimeInterval = 0
    var buttonDown = true
    var frontmost: pid_t? = 42
    var window: CGWindowID? = 7
    var reads = 0
    var translations = 0
    var readingCards = 0
    var failures: [String] = []
    var replayed: [CGEventType] = []
    var reading = SelectionReading(text: nil, diagnostic: "应用未提供选中文字")

    func monitor() -> RightPressMonitor {
        let environment = RightPressMonitor.Environment(now: { self.now },
            buttonIsDown: { self.buttonDown }, frontmostPID: { self.frontmost },
            foregroundWindow: { _, _ in self.window },
            readSelection: { _, _ in self.reads += 1; await self.read.wait(); return self.reading },
            waitForHold: { await self.hold.wait() },
            waitForReadTimeout: { await self.timeout.wait() },
            restore: { event, _, _, _, _ in self.replayed.append(event.type); return true })
        let monitor = RightPressMonitor(environment: environment)
        monitor.onTranslate = { _, _ in self.translations += 1 }
        monitor.onReading = { _ in self.readingCards += 1 }
        monitor.onSelectionFailure = { message, _ in self.failures.append(message) }
        return monitor
    }
    func event(_ type: CGEventType, x: CGFloat = 0) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: CGPoint(x: x, y: 0), mouseButton: .right)!
        event.timestamp = UInt64(now * 1_000_000_000)
        return event
    }
}

@MainActor
private final class PressGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in self.release() }
        }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
