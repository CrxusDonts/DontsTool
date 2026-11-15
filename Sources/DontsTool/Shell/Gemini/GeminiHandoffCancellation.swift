import AppKit
import Foundation

final class GeminiCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

@MainActor
protocol GeminiEscapeMonitoring: AnyObject {
    func start(_ onEscape: @escaping @Sendable () -> Void)
    func stop()
}

@MainActor
final class GeminiHandoffCancellation {
    private let monitor: any GeminiEscapeMonitoring
    private var flag = GeminiCancellationFlag()
    private var listening = false
    init(monitor: any GeminiEscapeMonitoring) { self.monitor = monitor }

    func prepare() -> GeminiCancellationFlag {
        finish()
        flag = GeminiCancellationFlag()
        return flag
    }

    func begin() {
        guard !listening, !flag.isCancelled else { return }
        listening = true
        let cancellation = flag
        monitor.start { cancellation.cancel() }
    }

    func finish() {
        flag.cancel()
        guard listening else { return }
        monitor.stop()
        listening = false
    }
}

@MainActor
final class SystemGeminiEscapeMonitor: GeminiEscapeMonitoring {
    private var local: Any?
    private var global: Any?

    func start(_ onEscape: @escaping @Sendable () -> Void) {
        stop()
        local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { onEscape() }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { onEscape() }
        }
    }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
    }
}
