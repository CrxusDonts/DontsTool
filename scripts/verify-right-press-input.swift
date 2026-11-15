import AppKit
import CoreGraphics
import Foundation

// Opt-in native input driver for the local browser fixture. Run only with explicit authorization.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let arguments = CommandLine.arguments
guard arguments.count == 6, arguments[1] == "--allow-global-input",
      let pid = pid_t(arguments[2]), let x = Double(arguments[3]),
      let y = Double(arguments[4]), let milliseconds = Double(arguments[5]),
      milliseconds >= 0, milliseconds <= 5000,
      let browser = NSRunningApplication(processIdentifier: pid),
      browser.bundleIdentifier == "com.microsoft.edgemac.Beta" else {
    fputs("Usage: verify-right-press-input.swift --allow-global-input EDGE_PID X Y HOLD_MS\n", stderr)
    exit(2)
}
guard CGPreflightPostEventAccess() else {
    fputs("Native event posting is unavailable; no permission request was made.\n", stderr)
    exit(3)
}
browser.activate(options: [.activateAllWindows])
let point = CGPoint(x: x, y: y)
let appKitPoint = NSPoint(x: x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - y)
func targetIsReady() -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    let hit = NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0)
    guard hit > 0,
          let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(hit)) as? [[String: Any]],
          let target = windows.first else { return false }
    return (target[kCGWindowOwnerPID as String] as? Int) == Int(pid)
        && (target[kCGWindowLayer as String] as? Int) == 0
}
let deadline = Date().addingTimeInterval(5)
while !targetIsReady(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
guard targetIsReady() else {
    fputs("Browser fixture is not the mouse target; no mouse input was sent.\n", stderr)
    exit(4)
}
let inputSource = CGEventSource(stateID: .hidSystemState)
guard let down = CGEvent(mouseEventSource: inputSource, mouseType: .rightMouseDown,
                         mouseCursorPosition: point, mouseButton: .right),
      let up = CGEvent(mouseEventSource: inputSource, mouseType: .rightMouseUp,
                       mouseCursorPosition: point, mouseButton: .right) else { exit(5) }
down.post(tap: .cghidEventTap)
let sampleDelay = min(milliseconds / 1000, 0.1)
Thread.sleep(forTimeInterval: sampleDelay)
print("Button state after down: combined=\(CGEventSource.buttonState(.combinedSessionState, button: .right)), hid=\(CGEventSource.buttonState(.hidSystemState, button: .right))")
Thread.sleep(forTimeInterval: max(0, milliseconds / 1000 - sampleDelay))
up.post(tap: .cghidEventTap)
print("Posted one right-button press for \(Int(milliseconds)) ms to the local acceptance fixture.")
