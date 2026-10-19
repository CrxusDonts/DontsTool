import CoreGraphics
import Foundation

/// Restore mouse events through WindowServer's normal routing, not directly to a PID.
@MainActor
enum RightPressEventReplay {
    enum Destination: Equatable { case tap(CGEventTapProxy), session }
    private static let marker: Int64 = 0x445453454C454354

    static func isReplay(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    @discardableResult
    static func restore(_ event: CGEvent, proxy: CGEventTapProxy?, sourcePID: pid_t,
                        frontmostPID: pid_t?, sameWindow: Bool,
                        post: @MainActor (CGEvent, Destination) -> Void = send) -> Bool {
        guard sourcePID > 0, frontmostPID == sourcePID, sameWindow else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        post(event, proxy.map(Destination.tap) ?? .session)
        return true
    }

    private static func send(_ event: CGEvent, to destination: Destination) {
        switch destination {
        case .tap(let proxy):
            // Quartz guarantees this event precedes the callback's returned event.
            event.tapPostEvent(proxy)
        case .session:
            event.post(tap: .cgSessionEventTap)
        }
    }
}
