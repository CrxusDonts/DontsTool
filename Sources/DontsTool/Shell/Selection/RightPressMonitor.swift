import AppKit
import ApplicationServices
import DontsToolCore

/// An active mouse-only tap is needed to prevent the source app's context menu.
/// The callback never waits for AX or network calls. Failed selection reads fail open.
@MainActor
final class RightPressMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = RightPressGesture()
    private var downEvent: CGEvent?
    private var sourcePID: pid_t = 0
    private var sourceWindow: CGWindowID?
    private var selection: String?
    private var requestID: UUID?
    private var selectionTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    var onTranslate: ((String, CGPoint) -> Void)?
    var onFailure: (() -> Void)?
    var ignoresPoint: ((CGPoint) -> Bool)?
    var isRunning: Bool { tap != nil }

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
                // This source is explicitly installed on the main run loop below.
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
        return true
    }

    func stop() {
        restoreDown()
        clearPending()
        gesture = RightPressGesture()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }

    private func handle(_ type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Bool {
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
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  !event.flags.contains(.maskControl), !event.flags.contains(.maskCommand),
                  !event.flags.contains(.maskAlternate), !event.flags.contains(.maskShift),
                  ignoresPoint?(event.location) != true,
                  let window = foregroundWindow(at: event, pid: pid),
                  let copy = event.copy() else { return true }
            sourcePID = pid; sourceWindow = window; downEvent = copy
            _ = gesture.down(at: now, point: event.location)
            let id = UUID(); requestID = id
            let point = event.location
            selectionTask = Task { [weak self] in
                let text = await SelectedTextReader.shared.read(pid: pid, at: point)
                guard let self, self.requestID == id else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    self.gesture.abandon(); self.clearPending(); return
                }
                self.selection = text
                self.apply(self.gesture.selectionResolved(available: text != nil,
                    at: ProcessInfo.processInfo.systemUptime,
                    buttonIsDown: CGEventSource.buttonState(.combinedSessionState, button: .right)))
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.requestID == id, self.selection == nil else { return }
                self.apply(self.gesture.selectionResolved(available: false, at: ProcessInfo.processInfo.systemUptime))
            }
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(RightPressGesture.holdDuration))
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                self.apply(self.gesture.advance(at: ProcessInfo.processInfo.systemUptime,
                    buttonIsDown: CGEventSource.buttonState(.combinedSessionState, button: .right)))
            }
            return false
        case .rightMouseUp:
            if downEvent != nil, NSWorkspace.shared.frontmostApplication?.processIdentifier != sourcePID {
                gesture.abandon()
            }
            let action = gesture.up(at: now)
            // Put the original down back at this tap, immediately before returning
            // the real up. Direct PID posting bypasses browser mouse routing.
            let forward = (action == .replayClick || action == .forward) && restoreDown(using: proxy)
            clearPending()
            return forward
        case .rightMouseDragged, .mouseMoved:
            let action = gesture.move(to: event.location)
            if action == .replayDown || (action == .forward && downEvent != nil) {
                let forward = restoreDown(using: proxy)
                clearPending()
                if !forward { gesture.abandon() }
                return forward
            }
            return action == .forward
        case .leftMouseDown, .scrollWheel, .flagsChanged:
            let action = gesture.cancel()
            if downEvent != nil, action != .hold {
                let restored = restoreDown(using: proxy)
                clearPending()
                if !restored { gesture.abandon() }
            }
            return true
        default: return true
        }
    }

    private func apply(_ action: RightPressGesture.Action) {
        switch action {
        case .replayDown:
            // AX may finish outside the tap callback. Keep the original down until
            // the next native callback so it can be restored using a valid proxy.
            cancelAsyncWork()
        case .translate:
            guard let selection, let downEvent,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return }
            onTranslate?(selection, downEvent.location)
            // Keep the gesture in its triggered phase until the physical mouse-up.
            self.downEvent = nil
            cancelAsyncWork()
        default: break
        }
    }

    @discardableResult
    private func restoreDown(using proxy: CGEventTapProxy? = nil) -> Bool {
        guard let downEvent else { return true }
        self.downEvent = nil
        return RightPressEventReplay.restore(downEvent, proxy: proxy, sourcePID: sourcePID,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            sameWindow: sourceWindow != nil && foregroundWindow(at: downEvent, pid: sourcePID) == sourceWindow)
    }

    private func foregroundWindow(at event: CGEvent, pid: pid_t) -> CGWindowID? {
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        if target > 0, target != Int64(pid) { return nil }
        // A right click may target a background app without first activating it.
        // Never replay that click into the app which merely had keyboard focus.
        let point = NSPoint(x: event.location.x,
            y: (NSScreen.screens.first?.frame.maxY ?? 0) - event.location.y)
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let window = windows.first,
              let owner = window[kCGWindowOwnerPID as String] as? Int,
              let layer = window[kCGWindowLayer as String] as? Int,
              owner == Int(pid), layer == 0 else { return nil }
        return CGWindowID(number)
    }

    private func clearPending() {
        downEvent = nil
        sourceWindow = nil
        cancelAsyncWork()
    }

    private func cancelAsyncWork() {
        requestID = nil; selection = nil
        selectionTask?.cancel(); selectionTask = nil
        holdTask?.cancel(); holdTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
    }
}
