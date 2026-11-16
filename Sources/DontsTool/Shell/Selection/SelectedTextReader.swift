import AppKit
import ApplicationServices
import Carbon

struct SelectionReading: Sendable {
    let text: String?
    let diagnostic: String
}

/// Copy is sent only to the captured source. Existing clipboard data is never used as a selection.
@MainActor
final class SelectedTextReader {
    @MainActor
    struct Environment {
        var frontmostPID: @MainActor () -> pid_t?
        var window: @MainActor (pid_t, CGPoint) -> CGWindowID?
        var sourceIsFocused: @MainActor (pid_t, CGPoint) async -> Bool
        var secureInput: @MainActor (pid_t) async -> Bool
        var postCopy: @MainActor (pid_t) -> Bool
        var changeCount: @MainActor () -> Int
        var copiedText: @MainActor () -> String?
        var pause: @MainActor () async throws -> Void

        static var system: Environment {
            Environment(frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                window: { pid, point in
                    guard let event = CGEvent(source: nil) else { return nil }
                    event.location = point
                    return RightPressMonitor.foregroundWindow(at: event, pid: pid)
                }, sourceIsFocused: { pid, point in
                    await Task.detached(priority: .userInitiated) { SelectedTextReader.sourceIsFocused(pid: pid, point: point) }.value
                }, secureInput: { pid in
                    await Task.detached(priority: .userInitiated) { SelectedTextReader.secureInputActive(pid: pid) }.value
                }, postCopy: { pid in
                    guard CGPreflightPostEventAccess(),
                          let source = CGEventSource(stateID: .privateState),
                          let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return false }
                    down.flags = .maskCommand; up.flags = .maskCommand
                    down.postToPid(pid); up.postToPid(pid)
                    return true
                }, changeCount: { NSPasteboard.general.changeCount },
                copiedText: { NSPasteboard.general.string(forType: .string) },
                pause: { try await Task.sleep(for: .milliseconds(10)) })
        }
    }

    nonisolated private static func sourceIsFocused(pid: pid_t, point: CGPoint) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        func element(_ name: String, of value: AXUIElement) -> AXUIElement? {
            AXUIElementSetMessagingTimeout(value, 0.15)
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(value, name as CFString, &result) == .success,
                  let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(result, to: AXUIElement.self)
        }
        guard let focusedWindow = element(kAXFocusedWindowAttribute, of: app) else { return false }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return false }
        var visited: [AXUIElement] = []
        for _ in 0..<12 {
            if current == focusedWindow { return true }
            if let window = element(kAXWindowAttribute, of: current) { return window == focusedWindow }
            guard !visited.contains(current) else { return false }
            visited.append(current)
            guard let parent = element(kAXParentAttribute, of: current) else { return false }
            current = parent
        }
        return false
    }

    nonisolated private static func secureInputActive(pid: pid_t) -> Bool {
        if IsSecureEventInputEnabled() { return true }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return subrole as? String == kAXSecureTextFieldSubrole
    }

    static let shared = SelectedTextReader()
    private let environment: Environment
    init(environment: Environment = .system) { self.environment = environment }

    func read(pid: pid_t, at point: CGPoint) async -> SelectionReading {
        func failure(_ message: String) -> SelectionReading { SelectionReading(text: nil, diagnostic: message) }
        guard !Task.isCancelled else { return failure("取词已取消") }
        guard environment.frontmostPID() == pid, let window = environment.window(pid, point),
              await environment.sourceIsFocused(pid, point) else {
            return failure("复制已取消：源应用或窗口发生变化")
        }
        guard !(await environment.secureInput(pid)) else { return failure("安全输入框不参与取词") }
        func sourceIsCurrent() async -> Bool {
            guard environment.frontmostPID() == pid, environment.window(pid, point) == window,
                  await environment.sourceIsFocused(pid, point) else { return false }
            return environment.frontmostPID() == pid && environment.window(pid, point) == window
        }
        let previousCount = environment.changeCount()
        guard await sourceIsCurrent() else { return failure("复制已取消：源应用或窗口发生变化") }
        guard !Task.isCancelled else { return failure("取词已取消") }
        guard environment.postCopy(pid) else { return failure("无法向源应用发送复制指令，请检查辅助功能授权") }
        for _ in 0..<60 {
            guard !Task.isCancelled else { return failure("取词已取消") }
            guard await sourceIsCurrent() else { return failure("复制已取消：源应用或窗口发生变化") }
            guard !Task.isCancelled else { return failure("取词已取消") }
            let copiedCount = environment.changeCount()
            if copiedCount != previousCount, let text = environment.copiedText(),
               environment.changeCount() == copiedCount {
                guard await sourceIsCurrent() else { return failure("复制已取消：源应用或窗口发生变化") }
                guard !Task.isCancelled else { return failure("取词已取消") }
                guard environment.changeCount() == copiedCount else { return failure("复制内容已变化，本次取词已取消") }
                let selected = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard selected.utf16.count <= 8000 else { return failure("选区超过 8000 字符限制") }
                if !selected.isEmpty { return SelectionReading(text: selected, diagnostic: "已通过源应用复制读取选区") }
            }
            do { try await environment.pause() }
            catch { return failure("取词已取消") }
        }
        return failure("本次复制未返回文字，请确认源应用中已选中文字")
    }
}
