import AppKit
import Combine
import DontsToolCore

/// The only network-backed tool host. The website owns authentication and document state.
@MainActor
final class KnowledgeWindowManager: KnowledgeServing {
    private let settings: SettingsStore
    private var controllers: [UUID: KnowledgeWindowController] = [:]
    private var enabledObservation: AnyCancellable?
    private var originObservation: AnyCancellable?
    private var searchGeneration = 0
    private var searchBridge: KnowledgeWebBridge?
    private var cascadePoint = NSPoint.zero
    private var preparingTermination = false
    private(set) var statusNotice: String?
    var onOpenSettings: (() -> Void)?
    var onSearchChanged: (() -> Void)?
    var hasOpenWindows: Bool { !controllers.isEmpty }

    init(settings: SettingsStore) {
        self.settings = settings
        enabledObservation = settings.$enabledProviderIDs
            .map { $0.contains(ProviderID.knowledge.rawValue) }.removeDuplicates()
            .sink { [weak self] enabled in
                if !enabled { self?.resetSearchConnection() }
            }
        originObservation = settings.$knowledgeBaseURL.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.resetSearchConnection() }
    }
    func openKnowledge(_ request: KnowledgeOpenRequest) {
        guard settings.isProviderEnabled(ProviderID.knowledge.rawValue), !preparingTermination else { return }
        do {
            let origin = try KnowledgeOrigin(settings.knowledgeBaseURL)
            let url = origin.url(for: request)
            // Compare the current URL because the page can navigate between articles in place.
            if request.surface != .capture,
               let existing = controllers.values.first(where: {
                   $0.bridge.origin == origin && $0.acceptsLauncherRequests && $0.bridge.webView.url == url
               }) {
                existing.show()
            } else {
                show(request, origin: origin)
            }
        }
        catch {
            let alert = NSAlert(); alert.messageText = "先连接你的知识库"
            alert.informativeText = "在设置 → 知识库中填写 DontsKb 服务地址，然后在知识库窗口内登录。"
            alert.addButton(withTitle: "打开设置"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { onOpenSettings?() }
        }
    }
    private func show(_ request: KnowledgeOpenRequest, origin: KnowledgeOrigin) {
        guard settings.isProviderEnabled(ProviderID.knowledge.rawValue), !preparingTermination else { return }
        let controller = KnowledgeWindowController(origin: origin, request: request, onSettings: { [weak self] in self?.onOpenSettings?() })
        controllers[controller.id] = controller
        controller.onClose = { [weak self, weak controller] in
            guard let id = controller?.id else { return }; self?.controllers.removeValue(forKey: id)
        }
        controller.bridge.onOpenDocument = { [weak self] request in self?.show(request, origin: origin) }
        let onAuthenticationChanged = controller.bridge.onAuthChanged
        controller.bridge.onAuthChanged = { [weak self] in
            onAuthenticationChanged?()
            guard let self, (try? KnowledgeOrigin(settings.knowledgeBaseURL)) == origin else { return }
            searchGeneration += 1
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
        guard settings.isProviderEnabled(ProviderID.knowledge.rawValue) else { throw KnowledgeBridgeError("知识库功能已关闭") }
        try Task.checkCancellation()
        let generation = searchGeneration
        // Connecting does not send the query. Overlap cold navigation with the typing pause.
        if let origin = try? KnowledgeOrigin(settings.knowledgeBaseURL), readyWindowBridge(for: origin) == nil {
            _ = backgroundBridge(for: origin)
        }
        try await Task.sleep(for: .milliseconds(180))
        try checkSearch(generation)
        do {
            let origin = try KnowledgeOrigin(settings.knowledgeBaseURL)
            if !(searchBridge?.origin == origin && searchBridge?.isReady == true),
               let visible = readyWindowBridge(for: origin),
               let items = try await search(visible, query: query, generation: generation) {
                return items
            }
            // An existing window may still belong to an older login. A new search page can read the current session.
            let background = backgroundBridge(for: origin)
            guard background.isReady else {
                if case .failed(let message) = background.state { throw KnowledgeBridgeError(message) }
                throw KnowledgeBridgeError("知识库正在连接，可打开知识库窗口登录")
            }
            guard let items = try await search(background, query: query, generation: generation) else {
                throw KnowledgeBridgeError("请先在知识库窗口登录")
            }
            return items
        } catch {
            if !Task.isCancelled, settings.isProviderEnabled(ProviderID.knowledge.rawValue), generation == searchGeneration { statusNotice = error.localizedDescription }
            throw error
        }
    }

    private func readyWindowBridge(for origin: KnowledgeOrigin) -> KnowledgeWebBridge? {
        controllers.values.first { $0.bridge.origin == origin && $0.acceptsLauncherRequests }?.bridge
    }

    private func backgroundBridge(for origin: KnowledgeOrigin) -> KnowledgeWebBridge {
        if let searchBridge, searchBridge.origin == origin { return searchBridge }
        searchBridge?.stop()
        let bridge = KnowledgeWebBridge(origin: origin, request: .init(surface: .search))
        searchBridge = bridge
        bridge.onReady = { [weak self, weak bridge] in
            guard let self, let bridge, searchBridge === bridge else { return }
            statusNotice = nil
            onSearchChanged?()
        }
        return bridge
    }

    private func search(_ bridge: KnowledgeWebBridge, query: String, generation: Int) async throws -> [KnowledgeSearchResult]? {
        let response = try await bridge.request(["type": "search", "query": String(query.prefix(2000))])
        try checkSearch(generation)
        let result = try JSONDecoder().decode(SearchResponse.self, from: Data(response.utf8))
        guard result.authenticated else { return nil }
        statusNotice = nil
        return result.items.prefix(8).map { .init(id: $0.id, title: $0.title, excerpt: $0.excerpt) }
    }

    private func checkSearch(_ generation: Int) throws {
        try Task.checkCancellation()
        guard settings.isProviderEnabled(ProviderID.knowledge.rawValue), generation == searchGeneration else {
            throw CancellationError()
        }
    }

    private func resetSearchConnection() {
        searchGeneration += 1
        searchBridge?.stop()
        searchBridge = nil
        statusNotice = nil
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
    func resumeInteraction() async {
        for controller in Array(controllers.values) { await controller.resumeInteraction() }
    }
    func shutdown() { resetSearchConnection(); controllers.values.forEach { $0.bridge.stop() } }
    private struct SearchResponse: Decodable {
        let authenticated: Bool
        let items: [Item]
        struct Item: Decodable { let id: String; let title: String; let excerpt: String? }
    }
}
