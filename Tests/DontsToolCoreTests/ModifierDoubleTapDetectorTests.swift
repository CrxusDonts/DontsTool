import Foundation
import Testing
@testable import DontsToolCore

@Suite("ModifierDoubleTapDetector")
struct ModifierDoubleTapDetectorTests {
    private func makeDetector() -> ModifierDoubleTapDetector {
        ModifierDoubleTapDetector(target: .option)
    }

    private func firstTap(
        _ detector: inout ModifierDoubleTapDetector,
        at start: TimeInterval,
        duration: TimeInterval = 0.08
    ) {
        let down = detector.update(activeModifiers: [.option], at: start)
        let up = detector.update(activeModifiers: [], at: start + duration)
        #expect(down == false)
        #expect(up == false)
    }

    @Test func twoQuickTapsFireOnSecondRelease() {
        var detector = makeDetector()
        firstTap(&detector, at: 0)
        let down = detector.update(activeModifiers: [.option], at: 0.18)
        let fired = detector.update(activeModifiers: [], at: 0.24)
        #expect(down == false)
        #expect(fired)
    }

    @Test func slowSecondTapDoesNotFire() {
        var detector = makeDetector()
        firstTap(&detector, at: 0)
        let fired = detector.update(activeModifiers: [.option], at: 0.5)
        #expect(fired == false)
    }

    @Test func longHoldDoesNotArm() {
        var detector = makeDetector()
        let down = detector.update(activeModifiers: [.option], at: 0)
        let up = detector.update(activeModifiers: [], at: 0.5)
        let secondPress = detector.update(activeModifiers: [.option], at: 0.55)
        #expect(down == false)
        #expect(up == false)
        #expect(secondPress == false)
    }

    @Test func keyDownBetweenTapsBreaksSequence() {
        var detector = makeDetector()
        firstTap(&detector, at: 0)
        detector.keyDown()
        let fired = detector.update(activeModifiers: [.option], at: 0.18)
        let release = detector.update(activeModifiers: [], at: 0.24)
        #expect(fired == false)
        #expect(release == false)
    }

    @Test func keyDownWhileHeldPreventsArming() {
        var detector = makeDetector()
        let down = detector.update(activeModifiers: [.option], at: 0)
        detector.keyDown()
        let up = detector.update(activeModifiers: [], at: 0.08)
        let secondPress = detector.update(activeModifiers: [.option], at: 0.18)
        let secondRelease = detector.update(activeModifiers: [], at: 0.24)
        #expect(down == false)
        #expect(up == false)
        #expect(secondPress == false)
        #expect(secondRelease == false)
    }

    @Test func otherModifierCancelsTap() {
        var detector = makeDetector()
        let optionDown = detector.update(activeModifiers: [.option], at: 0)
        let shiftDown = detector.update(activeModifiers: [.option, .shift], at: 0.03)
        let optionUp = detector.update(activeModifiers: [.shift], at: 0.08)
        let shiftUp = detector.update(activeModifiers: [], at: 0.12)
        let optionAgain = detector.update(activeModifiers: [.option], at: 0.18)
        #expect(optionDown == false)
        #expect(shiftDown == false)
        #expect(optionUp == false)
        #expect(shiftUp == false)
        #expect(optionAgain == false)
    }

    @Test func cooldownPreventsTripleTapDoubleFire() {
        var detector = makeDetector()
        firstTap(&detector, at: 0)
        let secondPress = detector.update(activeModifiers: [.option], at: 0.18)
        let firstFire = detector.update(activeModifiers: [], at: 0.25)
        let thirdPress = detector.update(activeModifiers: [.option], at: 0.3)
        #expect(firstFire)
        #expect(secondPress == false)
        #expect(thirdPress == false)
    }

    @Test func firesAgainAfterCooldown() {
        var detector = makeDetector()
        firstTap(&detector, at: 0)
        let secondPress = detector.update(activeModifiers: [.option], at: 0.18)
        let firstFire = detector.update(activeModifiers: [], at: 0.25)
        firstTap(&detector, at: 0.8)
        let nextPress = detector.update(activeModifiers: [.option], at: 0.98)
        let secondFire = detector.update(activeModifiers: [], at: 1.04)
        #expect(nextPress == false)
        #expect(firstFire)
        #expect(secondPress == false)
        #expect(secondFire)
    }

    @Test func longSecondPressDoesNotFire() {
        var detector = makeDetector()
        firstTap(&detector, at: 0)
        #expect(detector.update(activeModifiers: [.option], at: 0.18) == false)
        #expect(detector.update(activeModifiers: [], at: 0.6) == false)
    }

    @Test func otherModifierBetweenTapsBreaksSequence() {
        var detector = makeDetector()
        firstTap(&detector, at: 0)
        #expect(detector.update(activeModifiers: [.shift], at: 0.1) == false)
        #expect(detector.update(activeModifiers: [], at: 0.12) == false)
        #expect(detector.update(activeModifiers: [.option], at: 0.18) == false)
        #expect(detector.update(activeModifiers: [], at: 0.24) == false)
    }

    @Test func unchangedKeyCountAllowsDoubleTap() {
        var detector = makeDetector()
        #expect(detector.update(activeModifiers: [.option], at: 0, keyDownCount: 40) == false)
        #expect(detector.update(activeModifiers: [], at: 0.08, keyDownCount: 40) == false)
        #expect(detector.update(activeModifiers: [.option], at: 0.18, keyDownCount: 40) == false)
        let fired = detector.update(activeModifiers: [], at: 0.24, keyDownCount: 40)
        #expect(fired)
    }

    @Test func changedKeyCountBetweenTapsBreaksSequence() {
        var detector = makeDetector()
        #expect(detector.update(activeModifiers: [.option], at: 0, keyDownCount: 40) == false)
        #expect(detector.update(activeModifiers: [], at: 0.08, keyDownCount: 40) == false)
        #expect(detector.update(activeModifiers: [.option], at: 0.18, keyDownCount: 41) == false)
        #expect(detector.update(activeModifiers: [], at: 0.24, keyDownCount: 41) == false)
    }

    @Test func changedKeyCountDuringFirstPressPreventsArming() {
        var detector = makeDetector()
        #expect(detector.update(activeModifiers: [.option], at: 0, keyDownCount: 40) == false)
        #expect(detector.update(activeModifiers: [], at: 0.08, keyDownCount: 41) == false)
        #expect(detector.update(activeModifiers: [.option], at: 0.18, keyDownCount: 41) == false)
        #expect(detector.update(activeModifiers: [], at: 0.24, keyDownCount: 41) == false)
    }

    @Test func changedKeyCountDuringSecondPressPreventsFiring() {
        var detector = makeDetector()
        #expect(detector.update(activeModifiers: [.option], at: 0, keyDownCount: 40) == false)
        #expect(detector.update(activeModifiers: [], at: 0.08, keyDownCount: 40) == false)
        #expect(detector.update(activeModifiers: [.option], at: 0.18, keyDownCount: 40) == false)
        #expect(detector.update(activeModifiers: [], at: 0.24, keyDownCount: 41) == false)
    }

    @Test func wrappedKeyCountStillBreaksSequence() {
        var detector = makeDetector()
        #expect(detector.update(activeModifiers: [.option], at: 0, keyDownCount: .max) == false)
        #expect(detector.update(activeModifiers: [], at: 0.08, keyDownCount: .max) == false)
        #expect(detector.update(activeModifiers: [.option], at: 0.18, keyDownCount: 0) == false)
        #expect(detector.update(activeModifiers: [], at: 0.24, keyDownCount: 0) == false)
    }

    @Test func queuedModifierEventsCannotHideInterveningKeyDown() {
        var detector = makeDetector()
        // All callbacks run after a keyDown at 0.1 and see the same final counter.
        #expect(detector.update(activeModifiers: [.option], at: 0, keyDownCount: 41, latestKeyDownAt: 0.1) == false)
        #expect(detector.update(activeModifiers: [], at: 0.08, keyDownCount: 41, latestKeyDownAt: 0.1) == false)
        #expect(detector.update(activeModifiers: [.option], at: 0.18, keyDownCount: 41, latestKeyDownAt: 0.1) == false)
        #expect(detector.update(activeModifiers: [], at: 0.24, keyDownCount: 41, latestKeyDownAt: 0.1) == false)

        // A subsequent clean double tap still works.
        #expect(detector.update(activeModifiers: [.option], at: 0.8, keyDownCount: 41, latestKeyDownAt: 0.1) == false)
        #expect(detector.update(activeModifiers: [], at: 0.88, keyDownCount: 41, latestKeyDownAt: 0.1) == false)
        #expect(detector.update(activeModifiers: [.option], at: 0.98, keyDownCount: 41, latestKeyDownAt: 0.1) == false)
        let fired = detector.update(activeModifiers: [], at: 1.04, keyDownCount: 41, latestKeyDownAt: 0.1)
        #expect(fired)
    }
}
