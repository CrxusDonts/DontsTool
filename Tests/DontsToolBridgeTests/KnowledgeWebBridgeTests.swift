import AppKit
import DontsToolCore
import Foundation
import Testing
@preconcurrency import WebKit

@Suite("知识库 WebKit 插件协议", .serialized)
@MainActor
struct KnowledgeWebBridgeTests {
    @Test func readyTitleSearchAndCloseGuardTravelThroughRealWebKit() async throws {
        let server = try KnowledgeFixtureServer()
        defer { server.stop() }
        let bridge = try makeBridge(server)
        defer { bridge.stop() }
        var titles: [String] = []
        bridge.onTitle = { titles.append($0) }
        try await until { bridge.isReady && titles.contains("Fixture document") }
        #expect(bridge.hasBeenReady)

        let search = try await bridge.request(["type": "search", "query": "中文 + & \"quoted\"\nline"])
        let response = try #require(try JSONSerialization.jsonObject(with: Data(search.utf8)) as? [String: Any])
        #expect(response["authenticated"] as? Bool == true)
        let items = try #require(response["items"] as? [[String: Any]])
        #expect(items.first?["id"] as? String == "fixture-document")
        #expect(items.first?["excerpt"] as? String == "中文 + & \"quoted\"\nline")

        let close = try await bridge.request(["type": "prepareClose"])
        let closeResponse = try #require(try JSONSerialization.jsonObject(with: Data(close.utf8)) as? [String: Any])
        #expect(closeResponse["canClose"] as? Bool == false)
    }

    @Test func appearanceEventsTrackThePageAndRejectUnknownSchemes() async throws {
        let server = try KnowledgeFixtureServer()
        defer { server.stop() }
        let bridge = try makeBridge(server)
        defer { bridge.stop() }
        var schemes: [String] = []
        bridge.onAppearance = { schemes.append($0) }
        try await until { bridge.isReady && schemes == ["light"] }
        _ = try await bridge.request(["type": "reportAppearance", "scheme": "dark"])
        try await until { schemes == ["light", "dark"] }
        _ = try await bridge.request(["type": "reportAppearance", "scheme": "invalid"])
        _ = try await bridge.request(["type": "search", "query": "barrier"])
        #expect(schemes == ["light", "dark"])
    }

    @Test func compactWindowHasNativePinControlsAndKeepsPageSystemAppearanceIndependent() async throws {
        _ = NSApplication.shared
        let server = try KnowledgeFixtureServer()
        defer { server.stop() }
        let controller = KnowledgeWindowController(origin: try KnowledgeOrigin("http://127.0.0.1:\(server.port)"), request: .init(surface: .search), onSettings: {})
        defer { controller.bridge.stop(); controller.window?.close() }
        let window = try #require(controller.window)
        try await until { controller.bridge.isReady && window.appearance?.name == .aqua }
        #expect(window.toolbarStyle == .unifiedCompact)
        #expect(window.frame.width < 1040)
        let pin = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "knowledge.pin" })
        #expect(NSApp.sendAction(try #require(pin.action), to: pin.target, from: pin))
        #expect(window.level == .floating)
        #expect(NSApp.sendAction(try #require(pin.action), to: pin.target, from: pin))
        #expect(window.level == .normal)
        _ = try await controller.bridge.request(["type": "reportAppearance", "scheme": "dark"])
        try await until { window.appearance?.name == .darkAqua }
        // Forcing window chrome must not turn the page's system-theme preference
        // into a feedback loop through WKWebView's inherited appearance.
        #expect(controller.bridge.webView.appearance?.name == NSApp.effectiveAppearance.name)
    }

    @Test func sameOriginIframeCannotSendReadyTitleOrDocumentEvents() async throws {
        let server = try KnowledgeFixtureServer()
        defer { server.stop() }
        let bridge = try makeBridge(server, documentID: "iframe-test")
        defer { bridge.stop() }
        var titles: [String] = []
        var documents: [KnowledgeOpenRequest] = []
        var appearances: [String] = []
        bridge.onAppearance = { appearances.append($0) }
        bridge.onTitle = { titles.append($0) }
        bridge.onOpenDocument = { documents.append($0) }
        try await until { titles.contains("Iframe execution complete") }
        #expect(bridge.isReady)
        #expect(!titles.contains("Forged iframe title"))
        #expect(documents.isEmpty)
        #expect(appearances == ["light"])
    }

    @Test func selfRedirectOutsidePluginIsCancelledAndReloadReconnectsTool() async throws {
        let server = try KnowledgeFixtureServer()
        defer { server.stop() }
        let bridge = try makeBridge(server)
        defer { bridge.stop() }
        var readyCount = 0
        bridge.onReady = { readyCount += 1 }
        try await until { bridge.isReady }
        let navigation = KnowledgeNavigationRecorder(bridge: bridge)
        bridge.webView.navigationDelegate = navigation

        _ = try await bridge.request(["type": "tryNonPluginRedirect"])
        try await until({ navigation.decisions.contains { $0.url.path == "/workspace" } }, stage: "nonplugin redirect policy")
        #expect(navigation.decisions.first { $0.url.path == "/workspace" }?.policy == .cancel)
        #expect(bridge.webView.url?.path == "/tool")
        #expect(bridge.isReady)

        let previousReadyCount = readyCount
        bridge.reload()
        try await until({ bridge.isReady && readyCount > previousReadyCount }, stage: "ready after redirect/reload")
        #expect(bridge.webView.url?.path == "/tool")
    }

    @Test func incompatibleMainFrameProtocolRejectsRequests() async throws {
        let server = try KnowledgeFixtureServer()
        defer { server.stop() }
        let bridge = try makeBridge(server, documentID: "wrong-protocol")
        defer { bridge.stop() }
        try await until {
            if case .failed = bridge.state { return true }
            return false
        }
        #expect(!bridge.hasBeenReady)
        #expect(!bridge.isReady)
        await #expect(throws: KnowledgeBridgeError.self) {
            try await bridge.request(["type": "prepareClose"])
        }
    }

    @Test func reconnectAfterFirstProvisionalLoadFailureReachesReady() async throws {
        let reserved = try KnowledgeFixtureServer()
        let port = reserved.port
        reserved.stop()
        let origin = try KnowledgeOrigin("http://127.0.0.1:\(port)")
        let bridge = KnowledgeWebBridge(origin: origin, request: .init(surface: .search))
        defer { bridge.stop() }
        try await until {
            if case .failed = bridge.state { return true }
            return false
        }
        #expect(!bridge.hasBeenReady)
        // A stopped listener makes the first navigation fail before any document commits.
        #expect(bridge.webView.backForwardList.currentItem == nil)
        #expect(bridge.webView.url == nil)
        let server = try KnowledgeFixtureServer(port: port)
        defer { server.stop() }
        bridge.reload()
        try await until { bridge.isReady }
        #expect(bridge.hasBeenReady)
    }

    private func makeBridge(_ server: KnowledgeFixtureServer, documentID: String? = nil) throws -> KnowledgeWebBridge {
        KnowledgeWebBridge(origin: try KnowledgeOrigin("http://127.0.0.1:\(server.port)"), request: .init(surface: .editor, documentID: documentID))
    }

    private func until(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(12), stage: String = "protocol state") async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw FixtureError("等待 WebKit 超时: \(stage)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Records actual WebKit navigation decisions while preserving the real bridge delegate.
@MainActor
private final class KnowledgeNavigationRecorder: NSObject, WKNavigationDelegate {
    struct Decision {
        let url: URL
        let policy: WKNavigationActionPolicy
    }
    private let bridge: KnowledgeWebBridge
    private(set) var decisions: [Decision] = []
    init(bridge: KnowledgeWebBridge) { self.bridge = bridge }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        bridge.webView(webView, decidePolicyFor: action) { [weak self] policy in
            if let url = action.request.url { self?.decisions.append(.init(url: url, policy: policy)) }
            decisionHandler(policy)
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        bridge.webView(webView, didStartProvisionalNavigation: navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        bridge.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        bridge.webView(webView, didFail: navigation, withError: error)
    }
}

private struct FixtureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A controlled HTTP fixture; no account, cookie, storage, or remote endpoint is used.
@MainActor
private final class KnowledgeFixtureServer {
    let port: Int
    private let process: Process

    init(port: Int = 0) throws {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, String(port)]
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        self.process = process
        var line = Data()
        while line.count < 20 {
            let byte = stdout.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte.first == 10 { break }
            line.append(byte)
        }
        guard let value = Int(String(decoding: line, as: UTF8.self)), value > 0 else {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw FixtureError("本地 HTTP 测试服务未启动")
        }
        self.port = value
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }

    private static let script = #"""
import http.server, sys, urllib.parse

class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == '/tool' and query.get('documentId') == ['iframe-child']:
            html = '''<!doctype html><script>
            const post = data => window.webkit.messageHandlers.dontsTool.postMessage(data);
            post({type:'ready', version:999});
            post({type:'title', title:'Forged iframe title'});
            post({type:'openDocument', documentId:'forged-document'});
            post({type:'appearance', scheme:'dark'});
            parent.postMessage('iframe-finished', location.origin);
            </script>'''
        else:
            document = query.get('documentId', [''])[0]
            version = '999' if document == 'wrong-protocol' else '1'
            html = '''<!doctype html><meta charset="utf-8"><title>Fixture</title><script>
            const post = data => window.webkit.messageHandlers.dontsTool.postMessage(data);
            window.dontsToolPlugin = {request: async object => {
              if (object.type === 'search') return {authenticated:true, items:[{id:'fixture-document', title:'Fixture document', excerpt:object.query}]};
              if (object.type === 'prepareClose') return {canClose:false};
              if (object.type === 'reportAppearance') { post({type:'appearance', scheme:object.scheme}); return {accepted:true}; }
              if (object.type === 'tryNonPluginRedirect') { location.assign('/workspace'); return {accepted:true}; }
              return {accepted:true};
            }};
            post({type:'ready', version:VERSION});
            post({type:'appearance', scheme:'light'});
            post({type:'title', title:'  Fixture\\ndocument  '});
            </script>'''.replace('VERSION', version)
            if document == 'iframe-test':
                html += '''<script>
                window.addEventListener('message', event => {
                  if (event.origin === location.origin && event.data === 'iframe-finished') post({type:'title', title:'Iframe execution complete'});
                });
                </script><iframe src="/tool?mode=capture&amp;documentId=iframe-child"></iframe>'''
        body = html.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

class Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
server = Server(('127.0.0.1', int(sys.argv[1])), Fixture)
print(server.server_port, flush=True)
server.serve_forever()
"""#
}
