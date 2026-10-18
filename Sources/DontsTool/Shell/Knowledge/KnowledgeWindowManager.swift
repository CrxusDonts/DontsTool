import AppKit
import DontsToolCore

/// The only network-backed tool host. The website owns authentication and document state.
@MainActor
final class KnowledgeWindowManager: KnowledgeServing {
    private let settings: SettingsStore
    private var controllers: [UUID: KnowledgeWindowController] = [:]
    private var searchBridge: KnowledgeWebBridge?
    private var cascadePoint = NSPoint.zero
    private var preparingTermination = false
    private(set) var statusNotice: String?
    var onOpenSettings: (() -> Void)?
    var onSearchChanged: (() -> Void)?
    var hasOpenWindows: Bool { !controllers.isEmpty }

    init(settings: SettingsStore) { self.settings = settings }
    func openKnowledge(_ request: KnowledgeOpenRequest) {
        guard !preparingTermination else { return }
        do { show(request, origin: try KnowledgeOrigin(settings.knowledgeBaseURL)) }
        catch {
            let alert = NSAlert(); alert.messageText = "先连接你的知识库"
            alert.informativeText = "在设置 → 知识库中填写 DontsKb 服务地址，然后在知识库窗口内登录。"
            alert.addButton(withTitle: "打开设置"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { onOpenSettings?() }
        }
    }
    private func show(_ request: KnowledgeOpenRequest, origin: KnowledgeOrigin) {
        guard !preparingTermination else { return }
        let controller = KnowledgeWindowController(origin: origin, request: request, onSettings: { [weak self] in self?.onOpenSettings?() })
        controllers[controller.id] = controller
        controller.onClose = { [weak self, weak controller] in
            guard let id = controller?.id else { return }; self?.controllers.removeValue(forKey: id)
        }
        controller.bridge.onOpenDocument = { [weak self] request in self?.show(request, origin: origin) }
        let onAuthenticationChanged = controller.bridge.onAuthChanged
        controller.bridge.onAuthChanged = { [weak self] in
            onAuthenticationChanged?()
            guard let self else { return }
            // AuthSession deliberately blocks cross-login-boundary adoption. Only the disposable search client reloads.
            if searchBridge?.origin == origin { searchBridge?.reload() }
            statusNotice = nil; onSearchChanged?()
        }
        if cascadePoint == .zero { controller.window?.center() }
        else { _ = controller.window?.cascadeTopLeft(from: cascadePoint) }
        if let frame = controller.window?.frame { cascadePoint = NSPoint(x: frame.minX + 24, y: frame.maxY - 24) }
        controller.show()
    }
    func searchKnowledge(_ query: String) async throws -> [KnowledgeSearchResult] {
        // Scoped network search follows typing pauses; cancelled launcher generations never dispatch a new RPC.
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        let origin = try KnowledgeOrigin(settings.knowledgeBaseURL)
        let bridge: KnowledgeWebBridge
        if let existing = searchBridge, existing.origin == origin { bridge = existing }
        else {
            searchBridge?.stop()
            bridge = KnowledgeWebBridge(origin: origin, request: .init(surface: .search))
            searchBridge = bridge
            bridge.onReady = { [weak self] in self?.statusNotice = nil; self?.onSearchChanged?() }
        }
        guard bridge.isReady else {
            switch bridge.state {
            case .failed(let message): statusNotice = message
            default: statusNotice = "知识库正在连接，可打开知识库窗口登录"
            }
            throw KnowledgeBridgeError(statusNotice!)
        }
        do {
            let response = try await bridge.request(["type": "search", "query": String(query.prefix(2000))])
            try Task.checkCancellation()
            let result = try JSONDecoder().decode(SearchResponse.self, from: Data(response.utf8))
            guard result.authenticated else {
                statusNotice = "请先在知识库窗口登录"
                throw KnowledgeBridgeError(statusNotice!)
            }
            statusNotice = nil
            return result.items.prefix(8).map { .init(id: $0.id, title: $0.title, excerpt: $0.excerpt) }
        } catch {
            if !Task.isCancelled { statusNotice = error.localizedDescription }
            throw error
        }
    }
    func prepareToTerminate() async -> Bool {
        guard !preparingTermination else { return false }
        preparingTermination = true
        defer { preparingTermination = false }
        let windows = Array(controllers.values)
        for controller in windows {
            guard await controller.prepareToClose(lock: true) else {
                for window in windows { await window.resumeInteraction() }
                return false
            }
        }
        return true
    }
    func shutdown() { searchBridge?.stop(); controllers.values.forEach { $0.bridge.stop() } }
    private struct SearchResponse: Decodable {
        let authenticated: Bool
        let items: [Item]
        struct Item: Decodable { let id: String; let title: String; let excerpt: String? }
    }
}
