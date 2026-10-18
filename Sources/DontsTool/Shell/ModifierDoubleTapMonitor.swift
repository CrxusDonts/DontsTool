import AppKit
import CoreGraphics
import DontsToolCore

/// 仅观察修饰键变化；用系统事件计数打断组合输入，不订阅全局普通按键。
@MainActor
final class ModifierDoubleTapMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var detector: ModifierDoubleTapDetector?
    private var onDoubleTap: (() -> Void)?

    @discardableResult
    func start(
        modifier: SettingsStore.HotKeyConfiguration.Modifier,
        onDoubleTap: @escaping () -> Void
    ) -> Bool {
        stop()
        detector = ModifierDoubleTapDetector(target: modifier)
        self.onDoubleTap = onDoubleTap

        // AppKit 将这两个回调派发到主线程。全局 monitor 不接收本应用的事件。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            let time = event.timestamp
            MainActor.assumeIsolated {
                self?.handle(flags: flags, at: time)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            let time = event.timestamp
            MainActor.assumeIsolated {
                self?.handle(flags: flags, at: time)
            }
            return event
        }
        guard globalMonitor != nil, localMonitor != nil else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        detector = nil
        onDoubleTap = nil
    }

    private func handle(flags: NSEvent.ModifierFlags, at time: TimeInterval) {
        guard var detector else { return }
        // 先查询间隔、再取当前时间，使最近按键时间成为保守的上界。
        let keyDownAge = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let latestKeyDownAt = keyDownAge.isFinite
            ? ProcessInfo.processInfo.systemUptime - keyDownAge
            : nil
        let fired = detector.update(
            activeModifiers: Self.modifiers(from: flags),
            at: time,
            keyDownCount: CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown),
            latestKeyDownAt: latestKeyDownAt
        )
        self.detector = detector
        if fired { onDoubleTap?() }
    }

    private static func modifiers(
        from flags: NSEvent.ModifierFlags
    ) -> Set<SettingsStore.HotKeyConfiguration.Modifier> {
        var active: Set<SettingsStore.HotKeyConfiguration.Modifier> = []
        if flags.contains(.command) { active.insert(.command) }
        if flags.contains(.shift) { active.insert(.shift) }
        if flags.contains(.option) { active.insert(.option) }
        if flags.contains(.control) { active.insert(.control) }
        return active
    }
}
