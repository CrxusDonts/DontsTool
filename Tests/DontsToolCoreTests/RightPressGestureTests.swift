import Foundation
import Testing
@testable import DontsToolCore

@Suite("RightPressGesture")
struct RightPressGestureTests {
    @Test func shortClickIsReplayedInsteadOfTranslating() {
        var gesture = RightPressGesture()
        #expect(gesture.down(at: 10, point: .zero) == .hold)
        #expect(gesture.selectionResolved(available: true, at: 10.02) == .hold)
        #expect(gesture.up(at: 10.1) == .replayClick)
        #expect(gesture.advance(at: 11) == .forward)
    }

    @Test func twoSecondPressFiresOnlyOnceAndConsumesRelease() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        _ = gesture.selectionResolved(available: true, at: 0.01)
        #expect(gesture.advance(at: 1.99) == .hold)
        #expect(gesture.advance(at: 2) == .translate)
        #expect(gesture.advance(at: 2.1) == .hold)
        #expect(gesture.up(at: 2.2) == .hold)
        #expect(gesture.up(at: 3) == .forward)
    }

    @Test func oneAndHalfSecondsIsStillAnOrdinaryRightClick() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        _ = gesture.selectionResolved(available: true, at: 0.01)
        #expect(gesture.advance(at: 1.5) == .hold)
        #expect(gesture.up(at: 1.6) == .replayClick)
    }

    @Test func missingSelectionFallsBackToNativeRightClick() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        #expect(gesture.selectionResolved(available: false, at: 0.03) == .replayDown)
        #expect(gesture.advance(at: 0.7) == .forward)
        #expect(gesture.up(at: 0.8) == .forward)
    }

    @Test func movingBeyondToleranceRestoresRightDrag() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: CGPoint(x: 100, y: 100))
        _ = gesture.selectionResolved(available: true, at: 0.02)
        #expect(gesture.move(to: CGPoint(x: 104, y: 103)) == .hold)
        #expect(gesture.move(to: CGPoint(x: 109, y: 100)) == .replayDown)
        #expect(gesture.advance(at: 0.6) == .forward)
        #expect(gesture.up(at: 0.7) == .forward)
    }

    @Test func releasingBeforeTimerNeverStartsTranslation() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        _ = gesture.selectionResolved(available: true, at: 0.02)
        #expect(gesture.up(at: 2.5) == .replayClick)
        #expect(gesture.advance(at: 1) == .forward)
    }

    @Test func slowSelectionNeverTranslatesAfterRelease() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        #expect(gesture.advance(at: 0.5) == .hold)
        #expect(gesture.up(at: 0.7) == .replayClick)
        #expect(gesture.selectionResolved(available: true, at: 0.8) == .forward)
    }

    @Test func selectionArrivingAfterThresholdFiresWhileStillHeld() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        #expect(gesture.selectionResolved(available: true, at: 2.1) == .translate)
        #expect(gesture.up(at: 2.2) == .hold)
    }

    @Test func cancellingRestoresDownAndPreventsLateTrigger() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        _ = gesture.selectionResolved(available: true, at: 0.02)
        #expect(gesture.cancel() == .replayDown)
        #expect(gesture.advance(at: 1) == .forward)
        #expect(gesture.up(at: 1.1) == .forward)
    }

    @Test func modifiersAfterTriggerDoNotLeakAnUnpairedMouseUp() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        _ = gesture.selectionResolved(available: true, at: 0.02)
        #expect(gesture.advance(at: 2) == .translate)
        #expect(gesture.cancel() == .hold)
        #expect(gesture.up(at: 2.2) == .hold)
    }

    @Test func switchingApplicationsDiscardsBothSuppressedEvents() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        gesture.abandon()
        #expect(gesture.advance(at: 0.5) == .hold)
        #expect(gesture.selectionResolved(available: true, at: 0.6) == .hold)
        #expect(gesture.up(at: 2.2) == .hold)
    }

    @Test func delayedTimerCannotTurnReleasedShortClickIntoTranslation() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        _ = gesture.selectionResolved(available: true, at: 0.02)
        // Mouse-up physically occurred at 0.1, but the main run loop has not delivered it.
        #expect(gesture.advance(at: 0.7, buttonIsDown: false) == .hold)
        #expect(gesture.up(at: 0.1) == .replayClick)
    }

    @Test func delayedSelectionCannotTriggerAfterPhysicalRelease() {
        var gesture = RightPressGesture()
        _ = gesture.down(at: 0, point: .zero)
        #expect(gesture.selectionResolved(available: true, at: 0.7, buttonIsDown: false) == .hold)
        #expect(gesture.up(at: 0.1) == .replayClick)
    }
}
