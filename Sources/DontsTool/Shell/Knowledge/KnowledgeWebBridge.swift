import AppKit
import Combine
import DontsToolCore
@preconcurrency import WebKit

@MainActor
enum KnowledgeLoadState: Equatable {
    case loading, ready, failed(String)
}

/// A same-origin Web client. Credentials never cross this bridge.
@MainActor
final class KnowledgeWebBridge: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let origin: KnowledgeOrigin
    @Published private(set) var state: KnowledgeLoadState = .loading
    var onReady: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var onOpenDocument: ((KnowledgeOpenRequest) -> Void)?
    var onAuthChanged: (() -> Void)?
    var onAppearance: ((String) -> Void)?
    private var readyTimeout: DispatchWorkItem?
    private var pending: [UUID: (Result<String, Error>) -> Void] = [:]
    private let messageProxy = KnowledgeMessageProxy()
    private let initialURL: URL
    private(set) var hasBeenReady = false
    var isReady: Bool { state == .ready }

    init(origin: KnowledgeOrigin, request: KnowledgeOpenRequest) {
        self.origin = origin
        initialURL = origin.url(for: request)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        messageProxy.owner = self
        webView.configuration.userContentController.add(messageProxy, name: "dontsTool")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        load(origin.url(for: request))
    }

    func reload() {
        failPending("页面正在重新连接，请稍后重试")
        state = .loading
        if let url = webView.url, isPluginNavigation(url) { webView.reload() }
        else { webView.load(URLRequest(url: initialURL)) }
        scheduleReadyTimeout()
    }

    private func load(_ url: URL) {
        state = .loading
        webView.load(URLRequest(url: url))
        scheduleReadyTimeout()
    }
    private func scheduleReadyTimeout() {
        readyTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else { return }
            self.state = .failed("知识库尚未响应插件协议。请确认服务地址，并更新知识库 Web 服务后重试。")
        }
        readyTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    func request(_ object: [String: Any], timeout: TimeInterval = 8) async throws -> String {
        guard isReady else { throw KnowledgeBridgeError("知识库插件尚未就绪，请先打开知识库窗口连接或登录") }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = { continuation.resume(with: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(id, .failure(KnowledgeBridgeError("知识库请求超时，请重试；当前窗口及草稿已保留")))
            }
            webView.callAsyncJavaScript(
                "return JSON.stringify(await window.dontsToolPlugin.request(JSON.parse(payload)));",
                arguments: ["payload": payload], in: nil, in: .page
            ) { [weak self] result in
                switch result {
                case .success(let value):
                    guard let text = value as? String, text.utf8.count <= 256 * 1024 else {
                        self?.finish(id, .failure(KnowledgeBridgeError("知识库返回了无法识别的插件响应"))); return
                    }
                    self?.finish(id, .success(text))
                case .failure:
                    self?.finish(id, .failure(KnowledgeBridgeError("知识库请求未完成，请检查登录状态或稍后重试")))
                }
            }
        }
    }
    private func finish(_ id: UUID, _ result: Result<String, Error>) { pending.removeValue(forKey: id)?(result) }
    private func failPending(_ message: String) {
        let callbacks = Array(pending.values); pending.removeAll()
        callbacks.forEach { $0(.failure(KnowledgeBridgeError(message))) }
    }
    func stop() {
        readyTimeout?.cancel()
        webView.stopLoading()
        failPending("知识库窗口已关闭")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dontsTool")
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, origin.contains(url),
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            guard body["version"] as? Int == 1 else {
                state = .failed("知识库插件版本不兼容，请更新知识库服务及 DontsTool"); return
            }
            readyTimeout?.cancel(); hasBeenReady = true; state = .ready; onReady?()
        case "title":
            guard let title = body["title"] as? String else { return }
            let value = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { onTitle?(String(value.prefix(160))) }
        case "openDocument":
            guard let id = body["documentId"] as? String, !id.isEmpty, id.count <= 256 else { return }
            onOpenDocument?(KnowledgeOpenRequest(surface: .editor, documentID: id, blockID: body["blockId"] as? String))
        case "appearance":
            guard let scheme = body["scheme"] as? String, ["light", "dark"].contains(scheme) else { return }
            onAppearance?(scheme)
        case "authChanged": onAuthChanged?()
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if origin.contains(url), isPluginNavigation(url) {
            if action.targetFrame?.isMainFrame == true, action.navigationType == .linkActivated, isReady {
                Task { [weak self] in
                    guard let self else { decisionHandler(.cancel); return }
                    do {
                        let response = try await request(["type": "prepareClose"], timeout: 45)
                        let body = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
                        decisionHandler(body?["canClose"] as? Bool == true ? .allow : .cancel)
                    } catch { decisionHandler(.cancel) }
                }
            } else { decisionHandler(.allow) }
            return
        }
        if action.navigationType == .linkActivated { openExternal(url) }
        decisionHandler(.cancel)
    }
    private func isPluginNavigation(_ url: URL) -> Bool {
        if url.path == "/tool" { return true }
        if url.path == "/login" {
            let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect" }?.value
            return redirect == "/tool" || redirect?.hasPrefix("/tool?") == true
        }
        return false
    }
    private func openExternal(_ url: URL) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return }
        NSWorkspace.shared.open(url)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { openExternal(url) }
        return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state = .loading; failPending("知识库页面已切换，请重新执行操作"); scheduleReadyTimeout()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        readyTimeout?.cancel(); failPending("知识库连接已中断")
        state = .failed("无法连接知识库，请检查服务地址与网络后重试")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        readyTimeout?.cancel(); failPending("知识库页面进程已退出")
        state = .failed("知识库页面已暂停。重新连接后可恢复已有本地草稿。")
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard frame.isMainFrame, let url = frame.request.url, origin.contains(url), let window = webView.window else { completionHandler(false); return }
        let alert = NSAlert(); alert.messageText = "知识库操作确认"; alert.informativeText = String(message.prefix(3000))
        alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        guard frame.isMainFrame, let url = frame.request.url, origin.contains(url), let window = webView.window else { completionHandler(nil); return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories; panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}

@MainActor private final class KnowledgeMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: KnowledgeWebBridge?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}
struct KnowledgeBridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
