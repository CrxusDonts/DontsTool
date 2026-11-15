import AppKit
import ApplicationServices
import DontsToolCore
import os

/// The tap only routes mouse events. Accessibility and translation begin after a live two-second hold.
@MainActor
final class RightPressMonitor {
    @MainActor
    struct Environment {
        var now: @MainActor () -> TimeInterval
        var buttonIsDown: @MainActor () -> Bool
        var frontmostPID: @MainActor () -> pid_t?
        var foregroundWindow: @MainActor (CGEvent, pid_t) -> CGWindowID?
        var readSelection: @MainActor (pid_t, CGPoint) async -> SelectionReading
        var waitForHold: @MainActor () async throws -> Void
        var waitForReadTimeout: @MainActor () async throws -> Void
        var restore: @MainActor (CGEvent, CGEventTapProxy?, pid_t, pid_t?, Bool) -> Bool

        static var system: Environment {
            Environment(now: { ProcessInfo.processInfo.systemUptime },
                buttonIsDown: { CGEventSource.buttonState(.combinedSessionState, button: .right) },
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                foregroundWindow: RightPressMonitor.foregroundWindow,
                readSelection: { pid, point in await SelectedTextReader.shared.read(pid: pid, at: point) },
                waitForHold: { try await Task.sleep(for: .seconds(RightPressGesture.holdDuration)) },
                waitForReadTimeout: { try await Task.sleep(for: .seconds(3)) },
                restore: { event, proxy, source, frontmost, sameWindow in
                    RightPressEventReplay.restore(event, proxy: proxy, sourcePID: source,
                        frontmostPID: frontmost, sameWindow: sameWindow)
                })
        }
    }

    private let environment: Environment
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = RightPressGesture()
    private var downEvent: CGEvent?
    private var sourcePID: pid_t = 0
    private var sourceWindow: CGWindowID?
    private var requestID: UUID?
    private var selectionTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var activationObservation: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.donts.DontsTool", category: "selection-translation")
    var onDiagnostic: ((String) -> Void)?
    var onTranslate: ((String, CGPoint) -> Void)?
    var onReading: ((CGPoint) -> Void)?
    var onSelectionFailure: ((String, CGPoint) -> Void)?
    var onFailure: (() -> Void)?
    var ignoresPoint: ((CGPoint) -> Bool)?
    var isRunning: Bool { tap != nil }

    init(environment: Environment = .system) { self.environment = environment }

    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .mouseMoved, .leftMouseDown, .scrollWheel, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let forward = MainActor.assumeIsolated {
                    let monitor = Unmanaged<RightPressMonitor>.fromOpaque(context).takeUnretainedValue()
                    return monitor.handle(type, event: event, proxy: proxy)
                }
                return forward ? Unmanaged.passUnretained(event) : nil
            }, userInfo: context) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); return false
        }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        activationObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.requestID != nil,
                          self.environment.frontmostPID() != self.sourcePID else { return }
                    self.report("手势已取消：前台应用发生变化")
                    self.gesture.abandon(); self.clearPending()
                }
            }
        return true
    }

    /// Closing the card invalidates its AX result. Keep gesture routing intact until
    /// the physical release so a suppressed down never produces an unpaired up.
    func cancelPendingReading() {
        cancelAsyncWork()
    }

    func stop() {
        restoreDown()
        clearPending()
        gesture = RightPressGesture()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let activationObservation { NSWorkspace.shared.notificationCenter.removeObserver(activationObservation) }
        activationObservation = nil
        source = nil; tap = nil
    }

    func handle(_ type: CGEventType, event: CGEvent, proxy: CGEventTapProxy?) -> Bool {
        if RightPressEventReplay.isReplay(event) { return true }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            restoreDown(); clearPending(); gesture = RightPressGesture()
            DispatchQueue.main.async { [weak self] in self?.stop(); self?.onFailure?() }
            return true
        }
        let now = TimeInterval(event.timestamp) / 1_000_000_000
        switch type {
        case .rightMouseDown:
            guard downEvent == nil,
                  let pid = environment.frontmostPID(), pid != ProcessInfo.processInfo.processIdentifier else { return true }
            guard event.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift]).isEmpty,
                  ignoresPoint?(event.location) != true else {
                report("右键已放行：修饰键或翻译卡片区域"); return true
            }
            guard let window = environment.foregroundWindow(event, pid), let copy = event.copy() else {
                report("右键已放行：无法确认前台普通窗口"); return true
            }
            cancelAsyncWork()
            report("收到右键按下，等待持续按压满 2 秒")
            sourcePID = pid; sourceWindow = window; downEvent = copy
            _ = gesture.down(at: now, point: event.location)
            let id = UUID(); requestID = id
            holdTask = Task { [weak self] in
                guard let self else { return }
                do { try await self.environment.waitForHold() } catch { return }
                guard !Task.isCancelled, self.requestID == id else { return }
                guard self.sourceIsCurrent(copy) else {
                    self.report("手势已取消：前台应用或窗口发生变化")
                    self.gesture.abandon(); self.clearPending(); return
                }
                let isDown = self.environment.buttonIsDown()
                self.report(isDown ? "计时到达，右键仍在按下" : "计时到达，系统报告右键已松开")
                guard self.gesture.advance(at: self.environment.now(), buttonIsDown: isDown) == .translate else { return }
                self.beginReading(id: id, event: copy, pid: pid)
            }
            return false
        case .rightMouseUp:
            if downEvent != nil, !sourceIsCurrent(downEvent!) { gesture.abandon() }
            let action = gesture.up(at: now)
            if action == .hold {
                // A committed hold may finish reading after release. Both native mouse events stay suppressed.
                downEvent = nil
                return false
            }
            let forward = restoreDown(using: proxy)
            clearPending()
            return forward
        case .rightMouseDragged, .mouseMoved:
            let action = gesture.move(to: event.location)
            if action == .replayDown || (action == .forward && downEvent != nil) {
                if action == .replayDown { report("手势已取消：鼠标移动超过容差") }
                let forward = restoreDown(using: proxy)
                clearPending()
                if !forward { gesture.abandon() }
                return forward
            }
            // Suppress a right drag only while it is still a translation candidate.
            return type == .mouseMoved || action == .forward
        case .leftMouseDown, .scrollWheel, .flagsChanged:
            let action = gesture.cancel()
            if downEvent != nil, action != .hold {
                report("手势已取消：滚动、修饰键或其他点击")
                let restored = restoreDown(using: proxy)
                clearPending()
                if !restored { gesture.abandon() }
            }
            return true
        default: return true
        }
    }

    private func beginReading(id: UUID, event: CGEvent, pid: pid_t) {
        downEvent = nil
        report("持续按压满 2 秒，开始读取选区")
        onReading?(event.location)
        selectionTask = Task { [weak self] in
            guard let self else { return }
            let reading = await self.environment.readSelection(pid, event.location)
            guard !Task.isCancelled, self.requestID == id else { return }
            guard self.sourceIsCurrent(event) else {
                self.report("取词已取消：前台应用或窗口发生变化")
                self.clearPending(); return
            }
            self.report(reading.diagnostic)
            if let text = reading.text {
                self.report("已触发翻译卡片")
                self.onTranslate?(text, event.location)
            } else {
                self.onSelectionFailure?(reading.diagnostic, event.location)
            }
            self.cancelAsyncWork()
        }
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.environment.waitForReadTimeout() } catch { return }
            guard !Task.isCancelled, self.requestID == id else { return }
            let diagnostic = "读取选中文字超时，请点击编辑原文后翻译"
            self.report(diagnostic)
            if self.sourceIsCurrent(event) { self.onSelectionFailure?(diagnostic, event.location) }
            self.cancelAsyncWork()
        }
    }

    private func sourceIsCurrent(_ event: CGEvent) -> Bool {
        environment.frontmostPID() == sourcePID && sourceWindow != nil
            && environment.foregroundWindow(event, sourcePID) == sourceWindow
    }

    private func report(_ message: String) {
        logger.info("\(message, privacy: .public)")
        onDiagnostic?(message)
    }

    @discardableResult
    private func restoreDown(using proxy: CGEventTapProxy? = nil) -> Bool {
        guard let downEvent else { return true }
        self.downEvent = nil
        let sameWindow = sourceWindow != nil && environment.foregroundWindow(downEvent, sourcePID) == sourceWindow
        guard environment.frontmostPID() == sourcePID, sameWindow else { return false }
        return environment.restore(downEvent, proxy, sourcePID, environment.frontmostPID(), sameWindow)
    }

    private static func foregroundWindow(at event: CGEvent, pid: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // WindowServer order and Quartz bounds identify the actual pointer target. A new
        // nonactivating translation card must not hide its own source window during AX completion.
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int,
                  owner != ProcessInfo.processInfo.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(event.location),
                  let layer = window[kCGWindowLayer as String] as? Int else { continue }
            guard owner == Int(pid), layer == 0 else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }

    private func clearPending() {
        downEvent = nil
        sourceWindow = nil
        cancelAsyncWork()
    }

    private func cancelAsyncWork() {
        requestID = nil
        selectionTask?.cancel(); selectionTask = nil
        holdTask?.cancel(); holdTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
    }
}
