import AppKit
import os

private let windowLogger = Logger(subsystem: "com.donts.DontsTool", category: "selection-translation")

extension RightPressMonitor {
    @MainActor
    struct Environment {
        var now: @MainActor () -> TimeInterval
        var buttonIsDown: @MainActor () -> Bool
        var frontmostPID: @MainActor () -> pid_t?
        var foregroundWindow: @MainActor (CGEvent, pid_t) -> CGWindowID?
        var readSelection: @MainActor (pid_t, CGPoint) async -> SelectionReading
        var waitForHold: @MainActor (TimeInterval) async throws -> Void
        var waitForReadTimeout: @MainActor () async throws -> Void
        var restore: @MainActor (CGEvent, CGEventTapProxy?, pid_t, pid_t?, Bool) -> Bool

        var pointerEvent: @MainActor () -> CGEvent? = { CGEvent(source: nil) }

        var resumeTap: @MainActor (CFMachPort?) -> Bool = { tap in
            guard let tap else { return false }
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap)
        }

        static var system: Environment {
            Environment(now: { ProcessInfo.processInfo.systemUptime },
                // Suppressing down changes session state; HID state still reflects the held button.
                buttonIsDown: { CGEventSource.buttonState(.hidSystemState, button: .right) },
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                foregroundWindow: RightPressMonitor.foregroundWindow,
                readSelection: { pid, point in await SelectedTextReader.shared.read(pid: pid, at: point) },
                waitForHold: { try await Task.sleep(for: .seconds($0)) },
                waitForReadTimeout: { try await Task.sleep(for: .seconds(3)) },
                restore: { event, proxy, source, frontmost, sameWindow in
                    RightPressEventReplay.restore(event, proxy: proxy, sourcePID: source,
                        frontmostPID: frontmost, sameWindow: sameWindow)
                })
        }
    }

    static func scrollDistance(_ event: CGEvent) -> Double {
        let precise = abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            + abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        let points = abs(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            + abs(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        let discrete = abs(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            + abs(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        return max(precise, Double(points), Double(discrete))
    }

    static func hasScrollDelta(_ event: CGEvent) -> Bool {
        let discrete: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
            .scrollWheelEventDeltaAxis3, .scrollWheelEventPointDeltaAxis1,
            .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3]
        let precise: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1,
            .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3]
        return discrete.contains { event.getIntegerValueField($0) != 0 }
            || precise.contains { event.getDoubleValueField($0) != 0 }
    }

    static func foregroundWindow(at event: CGEvent, pid: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            windowLogger.info("窗口校验拒绝：系统未返回窗口列表")
            return nil
        }
        let point = event.location
        let appKitPoint = NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        return sourceWindow(at: point, frontmostPID: pid, ownPID: ProcessInfo.processInfo.processIdentifier,
            windows: windows, hitTest: { below in
                NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: below)
            })
    }

    static func sourceWindow(at point: CGPoint, frontmostPID pid: pid_t, ownPID: pid_t,
                             windows: [[String: Any]], hitTest: (Int) -> Int) -> CGWindowID? {
        var below = 0
        var visited = Set<Int>()
        while visited.count <= windows.count {
            let hit = hitTest(below)
            guard hit > 0, visited.insert(hit).inserted,
                  let window = windows.first(where: {
                      ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == hit
                  }), let owner = window[kCGWindowOwnerPID as String] as? Int else {
                windowLogger.info("窗口校验拒绝：鼠标未命中有效窗口，或窗口信息已经变化")
                return nil
            }
            // The nonactivating translation card may cover its source after reading begins.
            if owner == ownPID { below = hit; continue }
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else {
                windowLogger.info("窗口校验拒绝：命中窗口的边界信息无效")
                return nil
            }
            guard owner == Int(pid), layer == 0 else {
                windowLogger.info("窗口校验拒绝：实际命中窗口属于前台应用=\(owner == Int(pid))，层级=\(layer)")
                return nil
            }
            return CGWindowID(exactly: hit)
        }
        return nil
    }
}
