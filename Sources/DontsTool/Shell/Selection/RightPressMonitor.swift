import AppKit
import ApplicationServices
import DontsToolCore

/// An active mouse-only tap is needed to prevent the source app's context menu.
/// The callback never waits for AX or network calls. Failed selection reads fail open.
@MainActor
final class RightPressMonitor {
    private static let replayMarker: Int64 = 0x445453454C454354
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = RightPressGesture()
    private var downEvent: CGEvent?
    private var sourcePID: pid_t = 0
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
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // This source is explicitly installed on the main run loop below.
                let forward = MainActor.assumeIsolated {
                    let monitor = Unmanaged<RightPressMonitor>.fromOpaque(context).takeUnretainedValue()
                    return monitor.handle(type, event: event)
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
        replayDown()
        clearPending()
        gesture = RightPressGesture()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return true }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            replayDown(); clearPending(); gesture = RightPressGesture()
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
                  targetsForegroundWindow(event, pid: pid),
                  let copy = event.copy() else { return true }
            sourcePID = pid; downEvent = copy
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
            if requestID != nil, NSWorkspace.shared.frontmostApplication?.processIdentifier != sourcePID {
                gesture.abandon()
            }
            let action = gesture.up(at: now)
            if action == .replayClick {
                replayDown(); replay(event)
            } else { apply(action) }
            clearPending()
            return action == .forward
        case .rightMouseDragged, .mouseMoved:
            let action = gesture.move(to: event.location)
            if action == .replayDown {
                // Keep the restored down and first drag in the same directed stream.
                replayDown(); replay(event); clearPending()
                return false
            }
            apply(action)
            // Once cancelled, let the drag continue after the replayed down.
            return action == .forward || action == .replayDown
        case .leftMouseDown, .scrollWheel, .flagsChanged:
            apply(gesture.cancel())
            return true
        default: return true
        }
    }

    private func apply(_ action: RightPressGesture.Action) {
        switch action {
        case .replayDown:
            replayDown(); clearPending()
        case .translate:
            guard let selection, let downEvent,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return }
            onTranslate?(selection, downEvent.location)
            // Keep the gesture in its triggered phase until the physical mouse-up.
            self.downEvent = nil
            selectionTask?.cancel(); timeoutTask?.cancel(); holdTask?.cancel()
        default: break
        }
    }

    private func replayDown() {
        if let downEvent { replay(downEvent) }
        downEvent = nil
    }

    private func replay(_ event: CGEvent) {
        guard sourcePID > 0 else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        // Send delayed events only to their captured application, never a newly focused one.
        event.postToPid(sourcePID)
    }

    private func targetsForegroundWindow(_ event: CGEvent, pid: pid_t) -> Bool {
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        if target > 0, target != Int64(pid) { return false }
        // A right click may target a background app without first activating it.
        // Never replay that click into the app which merely had keyboard focus.
        let point = NSPoint(x: event.location.x,
            y: (NSScreen.screens.first?.frame.maxY ?? 0) - event.location.y)
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let window = windows.first,
              let owner = window[kCGWindowOwnerPID as String] as? Int,
              let layer = window[kCGWindowLayer as String] as? Int else { return false }
        return owner == Int(pid) && layer == 0
    }

    private func clearPending() {
        requestID = nil; downEvent = nil; selection = nil
        selectionTask?.cancel(); selectionTask = nil
        holdTask?.cancel(); holdTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
    }
}
