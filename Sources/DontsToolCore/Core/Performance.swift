import Foundation
import os

/// 性能埋点：signpost 区间 + 调试日志，用于验收第 8 节预算。
public enum Performance {
    public struct Interval {
        let name: StaticString
        let state: OSSignpostIntervalState
        let start: ContinuousClock.Instant
    }

    private static let signposter = OSSignposter(subsystem: "com.donts.DontsTool", category: "performance")
    private static let logger = Logger(subsystem: "com.donts.DontsTool", category: "performance")

    public static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name), start: .now)
    }

    public static func end(_ interval: Interval) {
        signposter.endInterval(interval.name, interval.state)
        logger.info("\(interval.name, privacy: .public) \(milliseconds(since: interval.start), privacy: .public)ms")
    }

    public static func mark(_ name: StaticString, since start: ContinuousClock.Instant) {
        logger.info("\(name, privacy: .public) \(milliseconds(since: start), privacy: .public)ms")
    }

    public static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }
}
