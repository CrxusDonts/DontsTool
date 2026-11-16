import AppKit
import DontsToolCore
import Testing

@Suite("Launcher dismissal", .serialized)
@MainActor
struct LauncherDismissalTests {
    @Test func losingFocusPreservesPanelAndQuery() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.prefill("ops avatar management")
        fixture.panel.delegate?.windowDidResignKey?(Notification(name: NSWindow.didResignKeyNotification, object: fixture.panel))
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.panel.isVisible)
        #expect(fixture.panel.alphaValue == 1)
        #expect(fixture.field.stringValue == "ops avatar management")
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
    func localOutsideClickDismissesAndStillReachesItsWindow(_ type: NSEvent.EventType) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let destination = ClickDestination(contentRect: fixture.panel.frame, styleMask: .borderless, backing: .buffered, defer: false)
        destination.isReleasedWhenClosed = false
        defer { destination.close() }
        NSApp.sendEvent(try click(type, window: destination))
        try await Task.sleep(for: .milliseconds(250))
        #expect(!fixture.panel.isVisible)
        #expect(destination.received == [type])
    }

    @Test func insideClickKeepsQueryAndReopeningRestoresOutsideMonitoring() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.prefill("json")
        NSApp.sendEvent(try click(.leftMouseDown, window: fixture.panel))
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.panel.isVisible)
        #expect(fixture.field.stringValue == "json")
        fixture.controller.hide(restorePreviousApp: false)
        try await Task.sleep(for: .milliseconds(250))
        fixture.controller.show()
        let destination = ClickDestination(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        destination.isReleasedWhenClosed = false
        defer { destination.close() }
        NSApp.sendEvent(try click(.leftMouseDown, window: destination))
        try await Task.sleep(for: .milliseconds(250))
        #expect(!fixture.panel.isVisible)
        #expect(destination.received == [.leftMouseDown])
    }

    @Test func outsideRightPressDismissesEvenWhenTranslationSuppressesNativeClick() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let monitor = RightPressMonitor(environment: .init(now: { 0 }, buttonIsDown: { true },
            frontmostPID: { 42 }, foregroundWindow: { _, _ in 7 },
            readSelection: { _, _ in SelectionReading(text: nil, diagnostic: "unused") },
            waitForHold: { _ in try await Task.sleep(for: .seconds(10)) },
            waitForReadTimeout: { try await Task.sleep(for: .seconds(10)) },
            restore: { _, _, _, _, _ in true }))
        let translation = SelectionTranslationController(settings: fixture.settings, translator: DismissalTranslator(), monitor: monitor)
        defer { translation.shutdown() }
        translation.onSuppressedMouseDown = { fixture.controller.hide(restorePreviousApp: false) }
        let down = try #require(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
            mouseCursorPosition: .zero, mouseButton: .right))
        #expect(!monitor.handle(.rightMouseDown, event: down, proxy: nil))
        try await Task.sleep(for: .milliseconds(250))
        #expect(!fixture.panel.isVisible)
    }

    private func click(_ type: NSEvent.EventType, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

@MainActor private struct Fixture {
    let controller: LauncherPanelController
    let panel: NSWindow
    let field: SearchField
    let settings: SettingsStore
    private let defaultsName: String

    init() throws {
        _ = NSApplication.shared
        defaultsName = "dontstool.dismissal.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: defaultsName)!)
        self.settings = settings
        let registry = ToolRegistry(providers: [])
        let feedback = DismissalFeedback()
        let controller = LauncherPanelController(registry: registry, coordinator: SearchCoordinator(registry: registry),
            toast: feedback, hotKeyDisplay: "⌥⌥", settings: settings,
            contentProvider: ContentActionProvider(settings: settings, toolOpener: DismissalTools(),
                urlOpener: DismissalURLs(), feedback: feedback))
        self.controller = controller
        controller.show()
        let panel = try #require(NSApp.windows.first { $0.delegate === controller })
        self.panel = panel
        func findField(_ view: NSView) -> SearchField? {
            if let field = view as? SearchField { return field }
            return view.subviews.lazy.compactMap(findField).first
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        field = try #require(panel.contentView.flatMap(findField))
    }

    func close() {
        controller.hide(restorePreviousApp: false)
        panel.orderOut(nil)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}

@MainActor private final class ClickDestination: NSWindow {
    var received: [NSEvent.EventType] = []
    override func sendEvent(_ event: NSEvent) { received.append(event.type) }
}
@MainActor private final class DismissalFeedback: FeedbackProviding { func show(_ message: String) {} }
@MainActor private final class DismissalTools: ToolOpening { func openTool(_ request: ToolOpenRequest) {} }
@MainActor private final class DismissalURLs: URLOpening { func open(_ url: URL) throws {} }
@MainActor private final class DismissalTranslator: TranslationServicing {
    let isConfigured = false
    func translate(_ text: String, target: String) async throws -> String { "" }
}
