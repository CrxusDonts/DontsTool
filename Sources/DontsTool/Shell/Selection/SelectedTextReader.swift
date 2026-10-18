import ApplicationServices
import Foundation

actor SelectedTextReader {
    static let shared = SelectedTextReader()
    /// Called only on a worker, for the application captured before the right press.
    /// No simulated Cmd-C, clipboard reads, OCR or text logging.
    func read(pid: pid_t, at point: CGPoint) -> String? {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: app),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var element = unsafeDowncast(focused, to: AXUIElement.self)
        // A process can own several documents. Reading the focused element alone
        // would translate window A's selection when the user right-clicks window B.
        var hit: AXUIElement?
        guard !Task.isCancelled,
              AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hit, let focusedWindow = window(of: element), let hitWindow = window(of: hit),
              CFEqual(focusedWindow, hitWindow) else { return nil }
        for _ in 0..<4 {
            let subrole = attribute(kAXSubroleAttribute, of: element) as? String
            guard subrole != kAXSecureTextFieldSubrole as String else { return nil }
            if let text = attribute(kAXSelectedTextAttribute, of: element) as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.utf16.count <= 8000 else { return nil }
                return trimmed
            }
            guard let parent = attribute(kAXParentAttribute, of: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    private func window(of element: AXUIElement) -> AXUIElement? {
        if attribute(kAXRoleAttribute, of: element) as? String == kAXWindowRole as String { return element }
        guard let window = attribute(kAXWindowAttribute, of: element),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(window, to: AXUIElement.self)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        guard !Task.isCancelled else { return nil }
        // AX timeouts are per element, not inherited from the application element.
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
