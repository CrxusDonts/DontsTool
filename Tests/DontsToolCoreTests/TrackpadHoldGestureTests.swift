import CoreGraphics
import Testing
@testable import DontsToolCore

@Suite("Two-finger trackpad hold")
struct TrackpadHoldGestureTests {
    private let cursor = CGPoint(x: 100, y: 100)
    private let fingers = [TrackpadHoldGesture.Contact(id: 10, x: 0.3, y: 0.5),
                           TrackpadHoldGesture.Contact(id: 20, x: 0.6, y: 0.5)]

    @Test(arguments: SelectionHoldDelay.allCases)
    func bothGesturesUseTheConfiguredDeadline(_ delay: SelectionHoldDelay) {
        var mouse = RightPressGesture(holdDuration: delay.seconds)
        _ = mouse.down(at: 0, point: cursor)
        #expect(mouse.advance(at: delay.seconds - 0.01) == .hold)
        #expect(mouse.advance(at: delay.seconds) == .translate)
        var touch = TrackpadHoldGesture(holdDuration: delay.seconds)
        _ = touch.update(fingers, at: 0, cursor: cursor)
        let count = Int((delay.seconds * 100).rounded())
        for tick in 1..<count {
            #expect(touch.update(fingers, at: Double(tick) / 100, cursor: cursor) == .none)
        }
        #expect(touch.update(fingers, at: delay.seconds, cursor: cursor) == .triggered)
        _ = touch.update([], at: delay.seconds + 0.01, cursor: cursor)
        #expect(touch.update(fingers, at: 10, cursor: cursor) == .began)
        for tick in 1..<count { _ = touch.update(fingers, at: 10 + Double(tick) / 100, cursor: cursor) }
        #expect(touch.update(fingers, at: 10 + delay.seconds, cursor: cursor) == .triggered)
    }

    @Test func stationaryTwoFingersTriggerWhileStillTouchingWithoutAMouseButton() {
        var gesture = TrackpadHoldGesture()
        #expect(gesture.update(fingers, at: 0, cursor: cursor) == .began)
        for step in 1..<20 {
            #expect(gesture.update(fingers.reversed(), at: Double(step) / 10, cursor: cursor) == .none)
        }
        #expect(gesture.update(fingers, at: 2, cursor: cursor) == .triggered)
        #expect(gesture.update(fingers, at: 2.1, cursor: cursor) == .none)
        #expect(gesture.update([], at: 2.2, cursor: cursor) == .ended)
    }

    @Test func shortTouchDoesNotTriggerAndNextTouchCanStart() {
        var gesture = TrackpadHoldGesture()
        _ = gesture.update(fingers, at: 0, cursor: cursor)
        #expect(gesture.update([], at: 0.2, cursor: cursor) == .ended)
        #expect(gesture.update(fingers, at: 1, cursor: cursor) == .began)
    }

    @Test func scrollingOrPinchingCancelsUntilAllFingersLift() {
        for moved in [TrackpadHoldGesture.Contact(id: 10, x: 0.34, y: 0.5),
                      TrackpadHoldGesture.Contact(id: 10, x: 0.3, y: 0.54)] {
            var gesture = TrackpadHoldGesture()
            _ = gesture.update(fingers, at: 0, cursor: cursor)
            #expect(gesture.update([moved, fingers[1]], at: 0.1, cursor: cursor) == .cancelled)
            #expect(gesture.update(fingers, at: 2, cursor: cursor) == .none)
            _ = gesture.update([], at: 3, cursor: cursor)
            #expect(gesture.update(fingers, at: 4, cursor: cursor) == .began)
        }
    }

    @Test func extraFingerOrReplacementCannotContinueTheHold() {
        for changed in [[fingers[0]], fingers + [.init(id: 30, x: 0.8, y: 0.5)],
                        [fingers[0], .init(id: 30, x: 0.6, y: 0.5)]] {
            var gesture = TrackpadHoldGesture()
            _ = gesture.update(fingers, at: 0, cursor: cursor)
            #expect(gesture.update(changed, at: 0.1, cursor: cursor) == .cancelled)
            #expect(gesture.update(fingers, at: 2, cursor: cursor) == .none)
        }
    }

    @Test func staleFramesAndCursorMovementCannotTrigger() {
        var stale = TrackpadHoldGesture()
        _ = stale.update(fingers, at: 0, cursor: cursor)
        #expect(stale.update(fingers, at: 3, cursor: cursor) == .cancelled)
        var moved = TrackpadHoldGesture()
        _ = moved.update(fingers, at: 0, cursor: cursor)
        #expect(moved.update(fingers, at: 0.1, cursor: CGPoint(x: 109, y: 100)) == .cancelled)
    }

    @Test func invalidCoordinatesAndDuplicateContactsFailClosed() {
        for bad in [[fingers[0], fingers[0]], [.init(id: 10, x: .nan, y: 0.5), fingers[1]]] {
            var gesture = TrackpadHoldGesture()
            #expect(gesture.update(bad, at: 0, cursor: cursor) != .began)
        }
    }
}
