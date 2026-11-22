import AppKit
import Combine
import DontsToolCore
import SwiftUI

@MainActor
protocol NativeQuickAICreating: AnyObject {
    func createQuickAIWindow()
}

@MainActor
final class QuickAIWindowManager {
    static let usageCanonicalKey = "plugin.com.donts.quick-ai.home"

    private let serviceResolver: @MainActor (String?) -> any AIChatServicing
    private let usage: UsageStore?
    private var controllers: [UUID: QuickAIWindowController] = [:]
    private var cascadePoint = NSPoint.zero

    var onOpenSettings: (() -> Void)?

    var openWindowCount: Int { controllers.count }
    var openSessions: [QuickAISession] { controllers.values.map(\.session) }

    convenience init(aiService: any AIChatServicing, usage: UsageStore? = nil) {
        self.init(
            serviceResolver: { consumerID in
                if let consumerID, let remote = aiService as? RemoteAIChatService {
                    return remote.scoped(toConsumerID: consumerID)
                }
                return aiService
            },
            usage: usage
        )
    }

    init(
        serviceResolver: @escaping @MainActor (String?) -> any AIChatServicing,
        usage: UsageStore? = nil
    ) {
        self.serviceResolver = serviceResolver
        self.usage = usage
    }

    @discardableResult
    func open(_ request: QuickAIRequest) -> QuickAISession {
        let initialTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (initialTitle?.isEmpty == false) ? initialTitle! : "AI 快问"
        let resolvedService = serviceResolver(request.consumerID)
        let session = QuickAISession(
            title: resolvedTitle,
            systemPrompt: request.systemPrompt,
            consumerID: request.consumerID,
            service: resolvedService
        )
        let controller = QuickAIWindowController(session: session, manager: self)

        if cascadePoint == .zero {
            controller.window?.center()
        } else {
            _ = controller.window?.cascadeTopLeft(from: cascadePoint)
        }
        if let frame = controller.window?.frame {
            cascadePoint = NSPoint(x: frame.minX + 24, y: frame.maxY - 24)
        }

        controllers[session.id] = controller
        session.applyInitialRequest(request)

        if let window = controller.window {
            NSApp.activate(ignoringOtherApps: true)
            window.deminiaturize(nil)
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }

        usage?.recordUse(of: Self.usageCanonicalKey)
        return session
    }

    @discardableResult
    func newWindow(consumerID: String? = nil) -> QuickAISession {
        open(QuickAIRequest(prompt: "", autoSend: false, consumerID: consumerID))
    }

    func window(for sessionID: UUID) -> NSWindow? {
        controllers[sessionID]?.window
    }

    func closeWindow(_ sessionID: UUID) {
        controllers[sessionID]?.close()
    }

    func openSettings() {
        onOpenSettings?()
    }

    func didClose(_ sessionID: UUID) {
        if let removed = controllers.removeValue(forKey: sessionID) {
            removed.session.stopStreaming()
        }
        if controllers.isEmpty {
            cascadePoint = .zero
        }
    }

    func shutdown() {
        let current = Array(controllers.values)
        controllers.removeAll()
        cascadePoint = .zero
        for controller in current {
            controller.session.stopStreaming()
            controller.window?.delegate = nil
            controller.close()
        }
    }
}

@MainActor
final class QuickAIWindowController: NSWindowController, NSWindowDelegate, NativeQuickAICreating {
    let session: QuickAISession
    private weak var manager: QuickAIWindowManager?
    private var titleObservation: AnyCancellable?
    private var pinObservation: AnyCancellable?

    init(session: QuickAISession, manager: QuickAIWindowManager) {
        self.session = session
        self.manager = manager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setContentSize(NSSize(width: 740, height: 560))
        window.contentMinSize = NSSize(width: 520, height: 400)
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? Theme.hexColor(0x1C1C1E)
                : Theme.hexColor(0xFAFAFB)
        }
        window.titlebarAppearsTransparent = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.delegate = self

        let consumerID = session.consumerID
        let rootView = QuickAIWindowView(
            session: session,
            onOpenSettings: { [weak manager] in manager?.openSettings() },
            onNewWindow: { [weak manager] in _ = manager?.newWindow(consumerID: consumerID) },
            onCloseWindow: { [weak window] in window?.performClose(nil) }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        window.contentView = hostingView

        titleObservation = session.$title.sink { [weak window] title in
            window?.title = title.isEmpty ? "AI 快问" : title
        }
        pinObservation = session.$isPinned.sink { [weak window] pinned in
            window?.level = pinned ? .floating : .normal
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func createQuickAIWindow() {
        _ = manager?.newWindow(consumerID: session.consumerID)
    }

    func windowWillClose(_ notification: Notification) {
        session.stopStreaming()
        manager?.didClose(session.id)
    }
}
