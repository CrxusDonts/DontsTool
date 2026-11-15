import ApplicationServices
import Foundation

/// The boundary keeps selection decisions testable without system permissions or synthetic input.
protocol SelectionAccessibility {
    associatedtype Element: Equatable
    var trusted: Bool { get }
    func application(_ pid: pid_t) -> Element
    func focusedElement(in app: Element) -> Element?
    func focusedWindow(in app: Element) -> Element?
    func element(at point: CGPoint, in app: Element) -> Element?
    func window(of element: Element) -> Element?
    func parent(of element: Element) -> Element?
    func isWindow(_ element: Element) -> Bool
    func isSecure(_ element: Element) -> Bool
    func selectedText(of element: Element) -> String?
}

struct SelectionReading: Sendable {
    let text: String?
    let diagnostic: String
}

enum SelectionTextExtraction {
    static func read<AX: SelectionAccessibility>(_ ax: AX, pid: pid_t, at point: CGPoint) -> SelectionReading {
        guard ax.trusted else { return failure("取词时辅助功能权限未生效") }
        let app = ax.application(pid)
        let focused = ax.focusedElement(in: app)
        guard let hit = ax.element(at: point, in: app) else { return failure("无法命中选区元素") }
        let hitPath = path(from: hit, in: app, ax: ax)
        let focusedPath = focused.map { path(from: $0, in: app, ax: ax) } ?? []
        let focusedWindow = focused.flatMap { ax.window(of: $0) }
            ?? focusedPath.first(where: { ax.isWindow($0) }) ?? ax.focusedWindow(in: app)
        let hitWindow = ax.window(of: hit) ?? hitPath.first(where: { ax.isWindow($0) })
        guard let focusedWindow, let hitWindow, focusedWindow == hitWindow else {
            return failure("无法确认焦点与鼠标位于同一选区窗口")
        }
        var candidates: [AX.Element] = []
        for element in hitPath + focusedPath {
            guard !Task.isCancelled else { return failure("取词已取消") }
            // A secure descendant must veto the entire attempt, even when an ancestor exposes text.
            guard !ax.isSecure(element) else { return failure("安全输入框不参与取词") }
            if ax.isWindow(element), element != hitWindow { return failure("选区路径跨越了窗口") }
            if let window = ax.window(of: element), window != hitWindow { return failure("选区路径跨越了窗口") }
            if !candidates.contains(element), !ax.isWindow(element) { candidates.append(element) }
        }
        for element in candidates {
            guard !Task.isCancelled else { return failure("取词已取消") }
            guard let text = ax.selectedText(of: element) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard trimmed.utf16.count <= 8000 else { return failure("选区超过 8000 字符限制") }
            return SelectionReading(text: trimmed, diagnostic: "已读取选区")
        }
        return failure("应用未提供选中文字")
    }

    private static func path<AX: SelectionAccessibility>(from start: AX.Element, in app: AX.Element, ax: AX) -> [AX.Element] {
        var path: [AX.Element] = []
        var element = start
        for _ in 0..<12 {
            guard !Task.isCancelled, element != app, !path.contains(element) else { break }
            path.append(element)
            if ax.isWindow(element) { break }
            guard let parent = ax.parent(of: element) else { break }
            element = parent
        }
        return path
    }

    private static func failure(_ message: String) -> SelectionReading {
        SelectionReading(text: nil, diagnostic: message)
    }
}

actor SelectedTextReader {
    static let shared = SelectedTextReader()
    /// AX work stays off the main event tap; never copy, read the clipboard or use OCR.
    func read(pid: pid_t, at point: CGPoint) -> SelectionReading {
        SelectionTextExtraction.read(SystemSelectionAccessibility(), pid: pid, at: point)
    }
}

private struct SystemSelectionAccessibility: SelectionAccessibility {
    var trusted: Bool { AXIsProcessTrusted() }
    func application(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
    func focusedElement(in app: AXUIElement) -> AXUIElement? { element(kAXFocusedUIElementAttribute, of: app) }
    func focusedWindow(in app: AXUIElement) -> AXUIElement? { element(kAXFocusedWindowAttribute, of: app) }
    func element(at point: CGPoint, in app: AXUIElement) -> AXUIElement? {
        guard !Task.isCancelled else { return nil }
        AXUIElementSetMessagingTimeout(app, 0.15)
        var hit: AXUIElement?
        return AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success ? hit : nil
    }
    func window(of value: AXUIElement) -> AXUIElement? { element(kAXWindowAttribute, of: value) }
    func parent(of value: AXUIElement) -> AXUIElement? { element(kAXParentAttribute, of: value) }
    func isWindow(_ value: AXUIElement) -> Bool { attribute(kAXRoleAttribute, of: value) as? String == kAXWindowRole }
    func isSecure(_ value: AXUIElement) -> Bool { attribute(kAXSubroleAttribute, of: value) as? String == kAXSecureTextFieldSubrole }
    func selectedText(of value: AXUIElement) -> String? { attribute(kAXSelectedTextAttribute, of: value) as? String }

    private func element(_ name: String, of value: AXUIElement) -> AXUIElement? {
        guard let result = attribute(name, of: value), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(result, to: AXUIElement.self)
    }
    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        guard !Task.isCancelled else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
