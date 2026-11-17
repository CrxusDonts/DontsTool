import AppKit
import Combine
import DontsToolCore
import ImageIO
@preconcurrency import WebKit

struct LocalNoteBridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class LocalNoteEditorBridge: NSObject, ObservableObject, WKNavigationDelegate {
    enum State: Equatable { case loading, ready, failed(String) }
    let webView: WKWebView
    let noteID: UUID
    @Published private(set) var state: State = .loading
    var onReady: (() -> Void)?
    var onChange: ((LocalNoteContent) -> Void)?
    var onError: ((String) -> Void)?
    private let store: LocalNoteStore
    private let proxy = LocalNoteMessageProxy()
    private var content: LocalNoteContent
    private var revision = -1
    private var timeout: DispatchWorkItem?
    private var stopped = false
    private var pendingSnapshots: [UUID: (Result<LocalNoteContent, Error>) -> Void] = [:]
    private var editable = true
    private var appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    private(set) var hasBeenReady = false
    private let initialURL: URL
    var pasteboard: NSPasteboard = .general

    init(note: LocalNoteRecord, store: LocalNoteStore, resourcesURL: URL? = nil) {
        noteID = note.id; self.store = store; content = note.content
        initialURL = URL(string: "donts-note://\(note.id.uuidString.lowercased())/index.html")!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(LocalNoteSchemeHandler(noteID: note.id, store: store,
            resourcesURL: resourcesURL ?? Bundle.main.resourceURL!.appendingPathComponent("NotesEditor")), forURLScheme: "donts-note")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        proxy.owner = self
        configuration.userContentController.add(proxy, name: "dontsNote")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        reload()
    }

    func reload() {
        guard !stopped else { return }
        revision = -1; state = .loading
        webView.load(URLRequest(url: initialURL))
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .loading else { return }
            self.state = .failed("编辑器未能加载，正文草稿已保留。")
        }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }
    func setEditable(_ value: Bool) {
        editable = value
        if state == .ready { run("window.dontsNote.setEditable(value)", arguments: ["value": value]) }
    }
    func setAppearance(_ value: String) {
        appearance = value
        guard state == .ready else { return }
        run("window.dontsNote.setAppearance(value)", arguments: ["value": value])
    }
    func focus() { if state == .ready { run("window.dontsNote.focus()") } }
    func snapshot(freeze: Bool = false) async throws -> LocalNoteContent {
        guard state == .ready else {
            if !hasBeenReady { return content }
            throw LocalNoteBridgeError("编辑器未就绪，草稿已保留。请重试加载后再关闭。")
        }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pendingSnapshots[id] = { continuation.resume(with: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.pendingSnapshots.removeValue(forKey: id)?(.failure(LocalNoteBridgeError("编辑器暂未响应，窗口和草稿已保留。")))
            }
            webView.callAsyncJavaScript("const value=window.dontsNote.snapshot(); if(freeze) window.dontsNote.setEditable(false); return value;", arguments: ["freeze": freeze], in: nil, in: .page) { [weak self] result in
                guard let self, let finish = self.pendingSnapshots.removeValue(forKey: id) else { return }
                switch result {
                case .failure(let error): finish(.failure(error))
                case .success(let value):
                    guard let decoded = Self.decodeContent(value) else { finish(.failure(LocalNoteBridgeError("无法取得最新正文，窗口已保留。"))); return }
                    if freeze { self.editable = false }
                    let capturedRevision = (value as? [String: Any])?["revision"] as? Int ?? self.revision
                    if capturedRevision >= self.revision { self.revision = capturedRevision; self.content = decoded }
                    finish(.success(self.content))
                }
            }
        }
    }

    func stop() {
        stopped = true; timeout?.cancel(); webView.stopLoading()
        let callbacks = Array(pendingSnapshots.values); pendingSnapshots.removeAll()
        callbacks.forEach { $0(.failure(LocalNoteBridgeError("便笺窗口已关闭。"))) }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dontsNote")
    }
    private func run(_ script: String, arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
            if case .failure = result { self?.onError?("编辑器操作未完成，草稿已保留。") }
        }
    }
    private static func decodeContent(_ value: Any?) -> LocalNoteContent? {
        guard let value = value as? [String: Any], let json = value["json"] as? String,
              let markdown = value["markdown"] as? String, let plainText = value["plainText"] as? String,
              [json, markdown, plainText].allSatisfy({ $0.utf8.count <= 4 * 1024 * 1024 }) else { return nil }
        return .init(json: json, markdown: markdown, plainText: plainText)
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard !stopped, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.host?.lowercased() == noteID.uuidString.lowercased(),
              message.frameInfo.request.url?.scheme == "donts-note",
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            guard body["version"] as? Int == 1 else { state = .failed("编辑器版本不兼容。"); return }
            timeout?.cancel()
            let payload: [String: Any] = ["noteID": noteID.uuidString.lowercased(), "content": ["json": content.json, "markdown": content.markdown, "plainText": content.plainText], "appearance": appearance]
            webView.callAsyncJavaScript("window.dontsNote.load(payload); window.dontsNote.setEditable(editable);", arguments: ["payload": payload, "editable": editable], in: nil, in: .page) { [weak self] result in
                guard let self, !self.stopped else { return }
                switch result {
                case .success: self.hasBeenReady = true; self.state = .ready; self.onReady?()
                case .failure: self.state = .failed("正文未能载入，原文件已保留。")
                }
            }
        case "change":
            guard editable, store.note(noteID) != nil, let next = body["revision"] as? Int, next > revision,
                  let value = Self.decodeContent(body["content"]) else { return }
            revision = next; content = value; onChange?(value)
        case "paste":
            guard editable, let token = body["token"] as? String else { return }
            resolveNativePaste(token: token, preferNativeImage: body["preferNativeImage"] as? Bool == true)
        case "importImage", "copyImage":
            guard editable, let token = body["token"] as? String, token.count <= 100 else { return }
            do {
                let asset: LocalNoteAsset
                if type == "copyImage" {
                    guard let source = body["sourceNoteID"] as? String, let id = UUID(uuidString: source), let path = body["relativePath"] as? String else { throw LocalNoteError.invalidAsset }
                    asset = try store.copyImage(from: id, relativePath: path, to: noteID)
                } else {
                    guard let base64 = body["base64"] as? String, base64.utf8.count <= 28 * 1024 * 1024,
                          let data = Data(base64Encoded: base64) else { throw LocalNoteError.invalidImage }
                    asset = try store.importImage(data, for: noteID)
                }
                run("window.dontsNote.insertImage(payload)", arguments: ["payload": ["token": token, "src": asset.relativePath]])
            } catch { resolveFailure(token: token, error: error) }
        case "openLink":
            if let value = body["url"] as? String, let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        case "error":
            if let text = body["message"] as? String { onError?(String(text.prefix(300))) }
        default: break
        }
    }
    private func resolveFailure(token: String, error: Error) {
        onError?(error.localizedDescription)
        run("window.dontsNote.resolvePaste(payload)", arguments: ["payload": ["token": token, "handled": true, "error": error.localizedDescription]])
    }
    private func resolveNativePaste(token: String, preferNativeImage: Bool) {
        do {
            // Rich HTML carries text and image ownership; the editor imports each asset without discarding text.
            if pasteboard.data(forType: .html) != nil && !preferNativeImage {
                run("window.dontsNote.resolvePaste(payload)", arguments: ["payload": ["token": token, "handled": false]])
                return
            }
            var assets: [LocalNoteAsset] = []
            if let data = pasteboard.data(forType: .png) { assets = [try store.importImage(data, for: noteID)] }
            else if let data = pasteboard.data(forType: .tiff) {
                assets = [try store.importImage(Self.clipboardPNG(fromTIFF: data), for: noteID)]
            } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                for url in urls.prefix(20) { assets.append(try store.importImageFile(url, for: noteID)) }
            }
            run("window.dontsNote.resolvePaste(payload)", arguments: ["payload": ["token": token, "handled": !assets.isEmpty, "images": assets.map { ["src": $0.relativePath, "alt": "图片"] }]])
        } catch { resolveFailure(token: token, error: error) }
    }
    private static func clipboardPNG(fromTIFF data: Data) throws -> Data {
        guard data.count <= 128 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, height <= 32_000_000, width <= 32_000_000 / height else { throw LocalNoteError.imageTooLarge }
        guard let image = NSBitmapImageRep(data: data), let png = image.representation(using: .png, properties: [:]) else { throw LocalNoteError.invalidImage }
        return png
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = action.request.url == initialURL && action.targetFrame?.isMainFrame == true && action.navigationType != .linkActivated
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { state = .failed("编辑器已断开，最近正文草稿已保留。") }
}

@MainActor
private final class LocalNoteMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: LocalNoteEditorBridge?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

@MainActor
final class LocalNoteSchemeHandler: NSObject, WKURLSchemeHandler {
    let noteID: UUID
    let store: LocalNoteStore
    let resourcesURL: URL
    init(noteID: UUID, store: LocalNoteStore, resourcesURL: URL) { self.noteID = noteID; self.store = store; self.resourcesURL = resourcesURL }
    func resource(for url: URL) throws -> (Data, String) {
        guard url.scheme == "donts-note", url.host?.lowercased() == noteID.uuidString.lowercased(), url.user == nil, url.password == nil, url.port == nil, url.query == nil,
              !url.absoluteString.contains("%"), !url.path.contains("..") else { throw LocalNoteError.unsafePath }
        let file: URL; let mime: String
        switch url.path {
        case "/index.html": file = resourcesURL.appendingPathComponent("index.html"); mime = "text/html"
        case "/editor.js": file = resourcesURL.appendingPathComponent("editor.js"); mime = "text/javascript"
        case "/editor.css": file = resourcesURL.appendingPathComponent("editor.css"); mime = "text/css"
        default:
            file = try store.assetURL(for: noteID, relativePath: String(url.path.dropFirst()))
            mime = ["png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][file.pathExtension] ?? "application/octet-stream"
        }
        guard (try FileManager.default.attributesOfItem(atPath: file.path)[.type]) as? FileAttributeType == .typeRegular else { throw LocalNoteError.unsafePath }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= (mime.hasPrefix("image/") ? 20 * 1024 * 1024 : 2 * 1024 * 1024) else { throw LocalNoteError.invalidAsset }
        return (try Data(contentsOf: file), mime)
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url else { throw LocalNoteError.unsafePath }
            let (data, mime) = try resource(for: url)
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
