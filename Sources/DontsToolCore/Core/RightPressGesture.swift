import Foundation
import CoreGraphics

/// Event routing decisions, independent of event taps, permissions and translation.
public struct RightPressGesture: Sendable {
    public enum Action: Equatable, Sendable {
        case forward, hold, replayDown, replayClick, translate
    }
    private enum Phase: Sendable { case idle, waiting, passedThrough, triggered }
    public static let holdDuration: TimeInterval = 2
    private var phase: Phase = .idle
    private var startedAt: TimeInterval = 0
    private var origin = CGPoint.zero

    private let duration: TimeInterval
    public init(holdDuration: TimeInterval = 2) { duration = holdDuration.isFinite && holdDuration > 0 ? holdDuration : 2 }

    public mutating func down(at time: TimeInterval, point: CGPoint) -> Action {
        phase = .waiting; startedAt = time; origin = point
        return .hold
    }

    public mutating func advance(at time: TimeInterval, buttonIsDown: Bool = true) -> Action {
        guard phase == .waiting else { return phase == .triggered ? .hold : .forward }
        if buttonIsDown, time - startedAt >= duration {
            return commitHold()
        }
        return .hold
    }

    /// A separately verified two-finger hold can commit the same suppressed mouse pair.
    public mutating func commitHold() -> Action {
        guard phase == .waiting else { return .forward }
        phase = .triggered
        return .translate
    }

    public mutating func move(to point: CGPoint) -> Action {
        guard phase == .waiting else { return phase == .triggered ? .hold : .forward }
        if hypot(point.x - origin.x, point.y - origin.y) > 8 {
            phase = .passedThrough
            return .replayDown
        }
        return .hold
    }

    public mutating func up(at _: TimeInterval) -> Action {
        defer { phase = .idle }
        switch phase {
        case .idle, .passedThrough: return .forward
        case .triggered: return .hold
        // Only a live hold may trigger translation. A delayed mouse-up must never
        // start a new request after the user has already released the button.
        case .waiting: return .replayClick
        }
    }

    public mutating func cancel() -> Action {
        guard phase != .triggered else { return .hold }
        let action: Action = phase == .waiting ? .replayDown : .forward
        phase = .passedThrough
        return action
    }

    /// Discard the suppressed pair if focus changes, without replaying into another app.
    public mutating func abandon() {
        phase = .triggered
    }
}
