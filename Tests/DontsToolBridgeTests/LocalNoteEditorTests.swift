import AppKit
import DontsToolCore
import Testing
@preconcurrency import WebKit

private final class NoteResourceMarker: NSObject {}

@Suite("本地便笺原生编辑器", .serialized)
@MainActor
struct LocalNoteEditorTests {
    @Test func updateThenQuitCapturesFrozenNotesOnceAndResumeInvalidatesApproval() async throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalNoteWindowManager(store: store, resourcesURL: resources)
        manager.openNote(record.id)
        let controller = try #require(manager.controllers[record.id])
        defer { manager.shutdown(); controller.window?.close() }
        try await until { controller.session.bridge.state == .ready }
        _ = try await js(controller.session.bridge, "window.captures=0; const original=window.dontsNote.snapshot; window.dontsNote.snapshot=()=>{window.captures++; return original();};")
        #expect(await manager.prepareToTerminate())
        #expect(await manager.prepareToTerminate())
        #expect(try await js(controller.session.bridge, "return window.captures;") as? Int == 1)
        manager.resumeEditing()
        #expect(await manager.prepareToTerminate())
        #expect(try await js(controller.session.bridge, "return window.captures;") as? Int == 2)
    }
    private var resources: URL { Bundle(for: NoteResourceMarker.self).resourceURL!.appendingPathComponent("NotesEditor") }
    private func fixture() throws -> (URL, LocalNoteStore, LocalNoteRecord) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("note-test-\(UUID())")
        let store = LocalNoteStore(rootURL: root)
        return (root, store, try store.create())
    }
    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LocalNoteBridgeError("等待编辑器状态超时") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    private func js(_ bridge: LocalNoteEditorBridge, _ code: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await bridge.webView.callAsyncJavaScript(code, arguments: args, in: nil, contentWorld: .page)
    }
    private func enterMarkdown(_ bridge: LocalNoteEditorBridge, _ text: String) async throws {
        _ = try await js(bridge, "document.querySelector('[data-mode=markdown]').click(); let field=document.querySelector('textarea'); field.value=text; field.dispatchEvent(new Event('input',{bubbles:true}));", ["text": text])
    }
    @Test func offlineBundleLoadsFormatsAutosavesAndRestores() async throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LocalNoteSession(record: record, store: store, resourcesURL: resources)
        defer { session.stop() }
        try await until { session.bridge.state == .ready }
        try await enterMarkdown(session.bridge, "# 发布排查\n\n**重点** 和 `code`\n\n- [ ] 验证服务\n\n```swift\nlet n = 1\n```")
        let saved = await session.captureAndFlush()
        #expect(saved)
        #expect(store.note(record.id)?.content.json.contains("heading") == true)
        #expect(store.note(record.id)?.content.json.contains("taskList") == true)
        #expect(store.note(record.id)?.title == "发布排查")
        let restarted = LocalNoteStore(rootURL: root)
        let restored = try #require(restarted.note(record.id))
        let bridge = LocalNoteEditorBridge(note: restored, store: restarted, resourcesURL: resources)
        defer { bridge.stop() }
        try await until { bridge.state == .ready }
        let snapshot = try await bridge.snapshot()
        #expect(snapshot.json == restored.content.json)
        #expect(snapshot.plainText.contains("验证服务"))
        let headingCount = try await js(bridge, "return document.querySelectorAll('.tiptap h1').length;") as? Int
        #expect(headingCount == 1)
    }
    @Test func nativeClipboardImageIsOwnedAndLoadsAfterRestart() async throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = LocalNoteEditorBridge(note: record, store: store, resourcesURL: resources)
        defer { bridge.stop() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        bridge.pasteboard = board
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        board.setData(png, forType: .png)
        board.setString("<img src=\"https://example.com/copied.png\">", forType: .html)
        try await until { bridge.state == .ready }
        _ = try await js(bridge, "let e=new Event('paste',{bubbles:true,cancelable:true}); Object.defineProperty(e,'clipboardData',{value:{getData:type=>type==='text/html'?'<img src=\"https://example.com/copied.png\">':'',files:[]}}); document.querySelector('.tiptap').dispatchEvent(e);")
        try await until { (try? store.search("").first.map { _ in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(record.id.uuidString).appendingPathComponent("assets"), includingPropertiesForKeys: nil).count > 0 }) == true }
        var snapshot: LocalNoteContent?
        for _ in 0..<100 {
            snapshot = try? await bridge.snapshot()
            if snapshot?.json.contains("assets/") == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let content = try #require(snapshot)
        #expect(content.json.contains("assets/"))
        #expect(!content.json.contains("donts-note:"))
        _ = try store.updateContent(record.id, content: content)
        let imageLoaded = try await js(bridge, "let i=document.querySelector('.tiptap img'); return !!i && i.complete && i.naturalWidth===8;") as? Bool
        #expect(imageLoaded == true)
        let reloaded = LocalNoteStore(rootURL: root)
        #expect(reloaded.note(record.id)?.content == content)
    }
    @Test func sourceValidationPreventsCloseAndKeepsLastSavedRecord() async throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LocalNoteSession(record: record, store: store, resourcesURL: resources)
        defer { session.stop() }
        try await until { session.bridge.state == .ready }
        try await enterMarkdown(session.bridge, "本地草稿")
        #expect(await session.captureAndFlush())
        let previous = store.note(record.id)?.content
        try await enterMarkdown(session.bridge, "![远程](https://example.com/private.png)")
        #expect(await session.captureAndFlush() == false)
        #expect(session.errorMessage != nil)
        #expect(store.note(record.id)?.content == previous)
    }
    @Test func earlierAutosaveDoesNotClearInvalidSourceError() async throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LocalNoteSession(record: record, store: store, resourcesURL: resources)
        defer { session.stop() }
        try await until { session.bridge.state == .ready }
        try await enterMarkdown(session.bridge, "有效草稿")
        try await enterMarkdown(session.bridge, "![远程](https://example.com/private.png)")
        try await until { session.errorMessage != nil }
        try await Task.sleep(for: .milliseconds(450))
        #expect(session.errorMessage != nil)
        #expect(session.status == "待完成编辑")
        #expect(store.note(record.id)?.content.plainText == "有效草稿")
    }
    @Test func lightAppearanceAndFreezeFailurePreserveEditableDraft() async throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LocalNoteSession(record: record, store: store, resourcesURL: resources)
        defer { session.stop() }
        session.bridge.setAppearance("light")
        try await until { session.bridge.state == .ready }
        #expect(try await js(session.bridge, "return document.documentElement.dataset.appearance;") as? String == "light")
        try await enterMarkdown(session.bridge, "待保存正文")
        let directory = root.appendingPathComponent(record.id.uuidString)
        let parked = root.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: directory, to: parked)
        #expect(await session.captureAndFlush(freeze: true) == false)
        try await until { session.errorMessage != nil }
        #expect(try await js(session.bridge, "return document.querySelector('textarea').readOnly;") as? Bool == false)
        try FileManager.default.moveItem(at: parked, to: directory)
        #expect(await session.captureAndFlush(freeze: true))
        #expect(try await js(session.bridge, "return document.querySelector('textarea').readOnly;") as? Bool == true)
        session.bridge.setEditable(true)
    }
    @Test func sameNoteFocusesExistingWindowAndDifferentNotesRemainSeparate() async throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalNoteWindowManager(store: store, resourcesURL: resources)
        defer { manager.shutdown(); Array(manager.controllers.values).forEach { $0.window?.close() } }
        manager.openNote(record.id)
        let first = try #require(manager.controllers[record.id])
        manager.openNote(record.id)
        #expect(manager.controllers.count == 1)
        #expect(manager.controllers[record.id] === first)
        manager.createNote()
        #expect(manager.controllers.count == 2)
        #expect(first.window?.hidesOnDeactivate == false)
        try await until { first.session.bridge.state == .ready }
        try await enterMarkdown(first.session.bridge, "窗口关闭前的最后输入")
        first.window?.performClose(nil)
        try await until { manager.controllers[record.id] == nil }
        #expect(store.note(record.id)?.content.plainText == "窗口关闭前的最后输入")
    }
    @Test func failedDiskWriteKeepsDraftAndTrashRejectsLateAutosave() async throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LocalNoteSession(record: record, store: store, resourcesURL: resources)
        defer { session.stop() }
        let content = LocalNoteContent(json: "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"保留草稿\"}]}]}", markdown: "保留草稿", plainText: "保留草稿")
        session.accept(content)
        let directory = root.appendingPathComponent(record.id.uuidString)
        let parked = root.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: directory, to: parked)
        #expect(session.flush() == false)
        #expect(session.draft == content)
        try FileManager.default.moveItem(at: parked, to: directory)
        #expect(session.flush())
        try store.trash(record.id)
        session.accept(.empty)
        #expect(session.flush() == false)
        #expect(store.note(record.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    @Test func renderRealEditorInBothAppearances() async throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 560, height: 100))
        image.lockFocus()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 560, height: 100).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.darkGray]
        ("Client  →  Gateway  →  Service" as NSString).draw(at: NSPoint(x: 24, y: 39), withAttributes: attributes)
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let asset = try store.importImage(data, for: record.id)
        let manager = LocalNoteWindowManager(store: store, resourcesURL: resources)
        defer { manager.shutdown(); Array(manager.controllers.values).forEach { $0.window?.close() } }
        manager.openNote(record.id)
        let controller = try #require(manager.controllers[record.id])
        let bridge = controller.session.bridge
        try await until { bridge.state == .ready }
        try await enterMarkdown(bridge, "# 发布排查片段\n\n随手记下 **排查结论**，代码和截图留在同一篇便笺。\n\n```sh\ncurl -s https://service.example/health\n```\n\n- [x] 检查服务状态\n- [ ] 记录后续操作\n\n![请求链路](\(asset.relativePath))")
        _ = try await js(bridge, "document.querySelector('[data-mode=wysiwyg]').click();")
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/local-notes")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in ["light", "dark"] {
            bridge.setAppearance(appearance)
            try await Task.sleep(for: .milliseconds(100))
            let config = WKSnapshotConfiguration(); config.rect = bridge.webView.bounds
            let screenshot = try await bridge.webView.takeSnapshot(configuration: config)
            let tiff = try #require(screenshot.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            #expect(png.count > 5000)
            try png.write(to: output.appendingPathComponent("editor-preview-\(appearance).png"))
        }
    }
    @Test func schemeRejectsForeignHostTraversalAndSymlinks() throws {
        let (root, store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = LocalNoteSchemeHandler(noteID: record.id, store: store, resourcesURL: resources)
        let host = record.id.uuidString.lowercased()
        #expect(try handler.resource(for: URL(string: "donts-note://\(host)/editor.js")!).0.count > 100_000)
        for text in ["donts-note://\(UUID())/index.html", "donts-note://\(host)/%2e%2e/secrets", "donts-note://\(host)/index.html?q=1", "file:///etc/passwd", "donts-note://\(host)/assets/../note.json"] {
            #expect(throws: (any Error).self) { try handler.resource(for: URL(string: text)!) }
        }
    }
}
