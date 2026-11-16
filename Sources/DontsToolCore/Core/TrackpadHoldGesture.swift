import Foundation
import CoreGraphics

/// Recognizes continuous contact, independent of macOS's synthesized mouse-button state.
public struct TrackpadHoldGesture: Sendable {
    public struct Contact: Sendable {
        public let id: Int
        public let x: Double
        public let y: Double
        public init(id: Int, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
    }
    public enum Action: Equatable, Sendable { case none, began, cancelled, triggered, ended }
    private enum Phase: Sendable { case idle, waiting, blocked, triggered }
    private var phase: Phase = .idle
    private var origins: [Int: CGPoint] = [:]
    private var cursorOrigin = CGPoint.zero
    private var startedAt: TimeInterval = 0
    private var lastFrameAt: TimeInterval = 0

    private let duration: TimeInterval
    public init(holdDuration: TimeInterval = 2) { duration = holdDuration.isFinite && holdDuration > 0 ? holdDuration : 2 }

    public mutating func update(_ contacts: [Contact], at time: TimeInterval, cursor: CGPoint) -> Action {
        if contacts.isEmpty {
            let wasActive = phase != .idle
            self = Self(holdDuration: duration)
            return wasActive ? .ended : .none
        }
        guard phase != .blocked, phase != .triggered else { return .none }
        guard contacts.count == 2, Set(contacts.map(\.id)).count == 2,
              contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            // One initial finger is normal; changing an established pair cancels this contact sequence.
            if phase == .idle, contacts.count == 1 { return .none }
            return block()
        }
        if phase == .idle {
            origins = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
            cursorOrigin = cursor; startedAt = time; lastFrameAt = time; phase = .waiting
            return .began
        }
        guard time >= lastFrameAt, time - lastFrameAt <= 0.3,
              hypot(cursor.x - cursorOrigin.x, cursor.y - cursorOrigin.y) <= 8,
              contacts.allSatisfy({ contact in
                  guard let origin = origins[contact.id] else { return false }
                  return hypot(contact.x - origin.x, contact.y - origin.y) <= 0.025
              }) else { return block() }
        lastFrameAt = time
        if time - startedAt >= duration {
            phase = .triggered
            return .triggered
        }
        return .none
    }

    public mutating func cancel() { if phase != .idle { phase = .blocked } }

    private mutating func block() -> Action {
        let wasWaiting = phase == .waiting
        phase = .blocked
        return wasWaiting ? .cancelled : .none
    }
}
