import AppKit
import DontsToolCore
import Testing

@Suite("Right press event routing", .serialized)
@MainActor
struct RightPressMonitorTests {
    @Test func twoFingerContactCanReadWithoutAnyMouseDownOrHIDButtonState() async {
        let fixture = RightPressFixture()
        fixture.buttonDown = false
        let monitor = fixture.monitor()
        monitor.handleTrackpad(1, action: .began)
        fixture.now = 2
        monitor.handleTrackpad(1, action: .triggered)
        await settle()
        #expect(fixture.readingCards == 1)
        #expect(fixture.reads == 1)
        #expect(fixture.replayed.isEmpty)
        monitor.stop()
    }

    @Test func rawHoldCommitsAPendingSecondaryClickEvenWhenHIDReportsReleased() async {
        let fixture = RightPressFixture()
        fixture.buttonDown = false
        let monitor = fixture.monitor()
        monitor.handleTrackpad(1, action: .began)
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        fixture.now = 2
        monitor.handleTrackpad(1, action: .triggered)
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed.isEmpty)
        monitor.stop()
    }

    @Test func cancelledTouchCannotTriggerOrStealTheNextNativeClick() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        monitor.handleTrackpad(1, action: .began)
        monitor.handleTrackpad(1, action: .cancelled)
        fixture.now = 2
        monitor.handleTrackpad(1, action: .triggered)
        await settle()
        #expect(fixture.reads == 0)
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        fixture.now = 2.1
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed == [.rightMouseDown])
        monitor.stop()
    }

    @Test func shortSecondaryClickCancelsTheRemainingContactHold() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        monitor.handleTrackpad(1, action: .began)
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        fixture.now = 0.15
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        fixture.now = 2
        monitor.handleTrackpad(1, action: .triggered)
        await settle()
        #expect(fixture.reads == 0)
        #expect(fixture.replayed == [.rightMouseDown])
        monitor.stop()
    }

    @Test func triggeredContactConsumesATapGeneratedOnLiftButNotLaterClicks() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        monitor.handleTrackpad(1, action: .began)
        fixture.now = 2
        monitor.handleTrackpad(1, action: .triggered)
        monitor.handleTrackpad(1, action: .ended)
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        fixture.now = 3
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        fixture.now = 3.15
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed == [.rightMouseDown])
        monitor.stop()
    }

    @Test func touchHoldCannotCrossApplicationsOrDevices() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        monitor.handleTrackpad(1, action: .began)
        fixture.now = 2
        monitor.handleTrackpad(2, action: .triggered)
        fixture.frontmost = 99
        monitor.handleTrackpad(1, action: .triggered)
        await settle()
        #expect(fixture.reads == 0)
        monitor.stop()
    }

    @Test func smallTrackpadScrollNoiseIsToleratedButAccumulatedScrollingCancels() async throws {
        for steps in [1, 8] {
            let fixture = RightPressFixture()
            let monitor = fixture.monitor()
            monitor.handleTrackpad(1, action: .began)
            _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
            await settle()
            let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 1, wheel2: 0, wheel3: 0))
            for _ in 0..<steps { _ = monitor.handle(.scrollWheel, event: scroll, proxy: nil) }
            fixture.now = 2
            monitor.handleTrackpad(1, action: .triggered)
            await settle()
            #expect(fixture.reads == (steps == 1 ? 1 : 0))
            #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil) == (steps > 1))
            monitor.stop()
        }
    }

    @Test func rawAndMouseHoldDeadlinesCannotReadTwice() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        monitor.handleTrackpad(1, action: .began)
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        await settle()
        fixture.now = 2
        fixture.hold.release()
        await settle()
        monitor.handleTrackpad(1, action: .triggered)
        await settle()
        #expect(fixture.reads == 1)
        #expect(fixture.readingCards == 1)
        monitor.stop()
    }

    @Test(arguments: SelectionHoldDelay.allCases)
    func configuredDelayReachesTheNativeTimer(_ delay: SelectionHoldDelay) async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        monitor.setHoldDelay(delay)
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        await settle()
        #expect(fixture.requestedDelays == [delay.seconds])
        fixture.now = delay.seconds
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        monitor.stop()
    }

    @Test func durationChangeCancelsAnInFlightPressAndRestoresItsNativePair() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        await settle()
        monitor.setHoldDelay(.milliseconds300)
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 0)
        #expect(fixture.replayed == [.rightMouseDown])
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        monitor.stop()
    }

    @Test func timedOutTapRecoversAndCanAcceptAnotherHold() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        var failures = 0
        monitor.onFailure = { failures += 1 }
        #expect(monitor.handle(.tapDisabledByTimeout, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        #expect(fixture.recoveryAttempts == 1)
        #expect(failures == 0)
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(fixture.readingCards == 1)
        monitor.stop()
    }

    @Test func timedOutPendingHoldRestoresNativePairAndCannotReadLate() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        #expect(monitor.handle(.tapDisabledByTimeout, event: fixture.event(.rightMouseDown), proxy: nil))
        fixture.now = 3
        fixture.hold.release()
        await settle()
        #expect(fixture.recoveryAttempts == 1)
        #expect(fixture.reads == 0)
        #expect(fixture.replayed == [.rightMouseDown])
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        monitor.stop()
    }

    @Test func timeoutAfterCommittedHoldPreservesReadingAndConsumesItsPhysicalRelease() async {
        let fixture = RightPressFixture()
        fixture.reading = SelectionReading(text: "word", diagnostic: "已读取选区")
        let monitor = fixture.monitor()
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        #expect(monitor.handle(.tapDisabledByTimeout, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        fixture.read.release()
        await settle()
        #expect(fixture.translations == 1)
        #expect(fixture.replayed.isEmpty)
        monitor.stop()
    }

    @Test func timeoutWithChangedSourceCannotLeakReleaseIntoAnotherWindow() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        fixture.window = 8
        #expect(monitor.handle(.tapDisabledByTimeout, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed.isEmpty)
        #expect(fixture.reads == 0)
        monitor.stop()
    }

    @Test func timeoutAfterNativeDragKeepsItsReleasePaired() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        #expect(monitor.handle(.rightMouseDragged, event: fixture.event(.rightMouseDragged, x: 20), proxy: nil))
        #expect(monitor.handle(.tapDisabledByTimeout, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed == [.rightMouseDown])
        monitor.stop()
    }

    @Test func timeoutAfterRestoringDownAlsoForwardsSmallNativeDrag() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        #expect(monitor.handle(.tapDisabledByTimeout, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        #expect(monitor.handle(.rightMouseDragged, event: fixture.event(.rightMouseDragged, x: 1), proxy: nil))
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed == [.rightMouseDown])
        #expect(fixture.reads == 0)
        monitor.stop()
    }

    @Test func failedRecoveryReportsPausedAndUserDisabledTapIsNotReenabled() async {
        for userDisabled in [false, true] {
            let fixture = RightPressFixture()
            fixture.recoverySucceeds = false
            let monitor = fixture.monitor()
            var failures = 0
            monitor.onFailure = { failures += 1 }
            #expect(monitor.handle(userDisabled ? .tapDisabledByUserInput : .tapDisabledByTimeout,
                event: fixture.event(.rightMouseDown), proxy: nil))
            await settle()
            #expect(failures == 1)
            #expect(fixture.recoveryAttempts == (userDisabled ? 0 : 1))
            monitor.stop()
        }
    }

    @Test func mouseHitTestIgnoresForeignClickThroughOverlay() {
        let windows = [window(20, owner: 200, layer: 20), window(7, owner: 100)]
        #expect(RightPressMonitor.sourceWindow(at: CGPoint(x: 50, y: 50), frontmostPID: 100,
            ownPID: 900, windows: windows, hitTest: { _ in 7 }) == 7)
    }

    @Test func mouseHitTestChoosesActualWindowAmongOverlappingSourceWindows() {
        let windows = [window(7, owner: 100), window(8, owner: 100)]
        #expect(RightPressMonitor.sourceWindow(at: CGPoint(x: 50, y: 50), frontmostPID: 100,
            ownPID: 900, windows: windows, hitTest: { _ in 8 }) == 8)
    }

    @Test func missingMouseHitNeverFallsBackToWindowRectangles() {
        #expect(RightPressMonitor.sourceWindow(at: CGPoint(x: 50, y: 50), frontmostPID: 100,
            ownPID: 900, windows: [window(7, owner: 100)], hitTest: { _ in 0 }) == nil)
    }

    @Test func actualForeignOrNonstandardWindowIsNotBypassed() {
        for target in [window(20, owner: 200, layer: 20), window(20, owner: 100, layer: 20),
                       window(20, owner: 200)] {
            #expect(RightPressMonitor.sourceWindow(at: CGPoint(x: 50, y: 50), frontmostPID: 100,
                ownPID: 900, windows: [target, window(7, owner: 100)], hitTest: { _ in 20 }) == nil)
        }
    }

    @Test func ownNonactivatingCardCanBeSkippedWithoutSkippingAnotherApplication() {
        var searches: [Int] = []
        let result = RightPressMonitor.sourceWindow(at: CGPoint(x: 50, y: 50), frontmostPID: 100,
            ownPID: 900, windows: [window(30, owner: 900), window(7, owner: 100)]) { below in
                searches.append(below)
                return below == 0 ? 30 : 7
            }
        #expect(result == 7)
        #expect(searches == [0, 30])
    }

    @Test func staleHitMetadataOrInvalidBoundsCannotBecomeASource() {
        let missing = RightPressMonitor.sourceWindow(at: CGPoint(x: 50, y: 50), frontmostPID: 100,
            ownPID: 900, windows: [window(7, owner: 100)], hitTest: { _ in 8 })
        #expect(missing == nil)
        let outside = RightPressMonitor.sourceWindow(at: CGPoint(x: 150, y: 150), frontmostPID: 100,
            ownPID: 900, windows: [window(7, owner: 100)], hitTest: { _ in 7 })
        #expect(outside == nil)
    }

    private func window(_ number: Int, owner: Int, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: number), kCGWindowOwnerPID as String: owner,
         kCGWindowLayer as String: layer, kCGWindowBounds as String:
            CGRect(x: 0, y: 0, width: 100, height: 100).dictionaryRepresentation]
    }

    @Test func explicitHoldHandlerSkipsSelectionAndKeepsItsMousePairSuppressed() async {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        var holds: [pid_t] = []
        monitor.onHold = { pid, _ in holds.append(pid) }
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(holds == [42])
        #expect(fixture.reads == 0)
        #expect(fixture.readingCards == 0)
        #expect(fixture.translations == 0)
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(fixture.replayed.isEmpty)
        monitor.stop()
    }

    @Test func zeroDeltaTrackpadScrollPhaseDoesNotCancelAnOtherwiseValidHold() async throws {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        let phaseOnly = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0))
        phaseOnly.setIntegerValueField(.scrollWheelEventScrollPhase, value: 128)
        #expect(monitor.handle(.scrollWheel, event: phaseOnly, proxy: nil))
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        #expect(fixture.replayed.isEmpty)
        monitor.stop()
    }

    @Test func fractionalOrDiscreteScrollStillCancelsHoldAndRestoresNativeDown() async throws {
        for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                      .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                      .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
            let fixture = RightPressFixture()
            let monitor = fixture.monitor()
            #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
            await settle()
            let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0))
            if field == .scrollWheelEventDeltaAxis1 || field == .scrollWheelEventDeltaAxis2
                || field == .scrollWheelEventPointDeltaAxis1 || field == .scrollWheelEventPointDeltaAxis2 {
                scroll.setIntegerValueField(field, value: 1)
            } else { scroll.setDoubleValueField(field, value: 0.25) }
            #expect(monitor.handle(.scrollWheel, event: scroll, proxy: nil))
            #expect(fixture.replayed == [.rightMouseDown])
            fixture.now = 2
            fixture.hold.release()
            await settle()
            #expect(fixture.reads == 0)
            #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
            monitor.stop()
        }
    }

    @Test func holdUsesTheInjectedMonotonicClockWhenEventTimestampHasAnotherOrigin() async throws {
        let fixture = RightPressFixture()
        fixture.now = 100
        let monitor = fixture.monitor()
        let down = fixture.event(.rightMouseDown)
        down.timestamp = 900_000_000_000
        #expect(!monitor.handle(.rightMouseDown, event: down, proxy: nil))
        await settle()
        fixture.now = 102
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        #expect(fixture.readingCards == 1)
        #expect(fixture.replayed.isEmpty)
        monitor.stop()
    }

    @Test func applicationActivationWithoutVisibleCardPreservesPendingHold() async throws {
        _ = NSApplication.shared
        let name = "dontstool.activation.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        let controller = SelectionTranslationController(
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "zh"),
            translator: UnconfiguredHoldTranslator(), monitor: monitor)
        defer { controller.shutdown() }
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        controller.dismissForApplicationChange()
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        #expect(controller.selectionReadInProgress)
        #expect(fixture.replayed.isEmpty)
    }

    @Test func releaseDiagnosticReportsShortPressDurationAndNativeClickRestoration() async throws {
        let fixture = RightPressFixture()
        let monitor = fixture.monitor()
        var diagnostics: [String] = []
        monitor.onDiagnostic = { diagnostics.append($0) }
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        fixture.now = 0.6
        #expect(monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(diagnostics.last?.contains("0.6") == true)
        #expect(diagnostics.last?.contains("未满 2 秒") == true)
        #expect(fixture.replayed == [.rightMouseDown])
        #expect(fixture.reads == 0)
        monitor.stop()
    }

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
        var diagnostics: [String] = []
        monitor.onDiagnostic = { diagnostics.append($0) }
        #expect(!monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil))
        await settle()
        #expect(fixture.reads == 0)
        fixture.now = 2
        fixture.hold.release()
        await settle()
        #expect(fixture.reads == 1)
        #expect(fixture.readingCards == 1)
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(diagnostics.last?.contains("长按已触发") == true)
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
        var diagnostics: [String] = []
        monitor.onDiagnostic = { diagnostics.append($0) }
        _ = monitor.handle(.rightMouseDown, event: fixture.event(.rightMouseDown), proxy: nil)
        fixture.window = 9
        #expect(!monitor.handle(.rightMouseUp, event: fixture.event(.rightMouseUp), proxy: nil))
        #expect(diagnostics.last?.contains("手势已取消") == true)
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
private final class UnconfiguredHoldTranslator: TranslationServicing {
    let isConfigured = false
    func translate(_ text: String, target: String) async throws -> String {
        Issue.record("A pending hold must not send a translation request")
        return ""
    }
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
    var requestedDelays: [TimeInterval] = []
    var recoveryAttempts = 0
    var recoverySucceeds = true
    var reads = 0
    var translations = 0
    var readingCards = 0
    var failures: [String] = []
    var replayed: [CGEventType] = []
    var reading = SelectionReading(text: nil, diagnostic: "应用未提供选中文字")

    func monitor() -> RightPressMonitor {
        var environment = RightPressMonitor.Environment(now: { self.now },
            buttonIsDown: { self.buttonDown }, frontmostPID: { self.frontmost },
            foregroundWindow: { _, _ in self.window },
            readSelection: { _, _ in self.reads += 1; await self.read.wait(); return self.reading },
            waitForHold: { delay in self.requestedDelays.append(delay); await self.hold.wait() },
            waitForReadTimeout: { await self.timeout.wait() },
            restore: { event, _, _, _, _ in self.replayed.append(event.type); return true })
        environment.pointerEvent = { self.event(.mouseMoved) }
        environment.resumeTap = { _ in self.recoveryAttempts += 1; return self.recoverySucceeds }
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
