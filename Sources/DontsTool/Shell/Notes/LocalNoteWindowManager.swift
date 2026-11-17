import AppKit
import Combine
import DontsToolCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol NativeNoteCreating: AnyObject { func createNoteWindow() }

@MainActor
final class LocalNoteWindowManager: LocalNoteOpening {
    let store: LocalNoteStore
    private(set) var controllers: [UUID: LocalNoteWindowController] = [:]
    private var cascadePoint = NSPoint.zero
    private let resourcesURL: URL?
    init(store: LocalNoteStore, resourcesURL: URL? = nil) { self.store = store; self.resourcesURL = resourcesURL }
    var hasOpenWindows: Bool { !controllers.isEmpty }
    func createNote() {
        do { open(try store.create()) } catch { showError(error.localizedDescription) }
    }
    func openNote(_ id: UUID) {
        guard let record = store.note(id) else { return }
        open(record)
    }
    private func open(_ record: LocalNoteRecord) {
        let controller: LocalNoteWindowController
        if let existing = controllers[record.id] { controller = existing }
        else {
            controller = LocalNoteWindowController(session: LocalNoteSession(record: record, store: store, resourcesURL: resourcesURL), owner: self)
            controllers[record.id] = controller
            if cascadePoint == .zero { controller.window?.center() }
            else { _ = controller.window?.cascadeTopLeft(from: cascadePoint) }
            if let frame = controller.window?.frame { cascadePoint = NSPoint(x: frame.minX + 24, y: frame.maxY - 24) }
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.deminiaturize(nil)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func restore(_ id: UUID) {
        if let controller = controllers[id] { controller.session.restore(); openNote(id) }
        else { do { open(try store.restore(id)) } catch { showError(error.localizedDescription) } }
    }
    func didClose(_ id: UUID) { controllers.removeValue(forKey: id)?.session.stop() }
    func prepareToTerminate() async -> Bool {
        for controller in Array(controllers.values) {
            guard await controller.session.captureAndFlush(freeze: true) else {
                resumeEditing()
                controller.window?.makeKeyAndOrderFront(nil)
                showError(controller.session.errorMessage ?? "便笺尚未保存，退出已取消。")
                return false
            }
        }
        return true
    }
    func resumeEditing() { controllers.values.filter { !$0.session.isTrashed }.forEach { $0.session.bridge.setEditable(true) } }
    func shutdown() { controllers.values.forEach { $0.session.stop() } }
    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "便笺操作未完成"; alert.informativeText = message
        alert.addButton(withTitle: "好"); alert.runModal()
    }
}

@MainActor
final class LocalNoteWindowController: NSWindowController, NSWindowDelegate, NativeNoteCreating {
    let session: LocalNoteSession
    private weak var manager: LocalNoteWindowManager?
    private var observation: AnyCancellable?
    private var closing = false
    private var approvedClose = false
    init(session: LocalNoteSession, owner: LocalNoteWindowManager) {
        self.session = session; self.manager = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 600, height: 440)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true; window.backgroundColor = ToolTheme.shellNS
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        session.bridge.onReady = { [weak window, weak bridge = session.bridge] in
            if window?.isKeyWindow == true, let bridge { window?.makeFirstResponder(bridge.webView); bridge.focus() }
        }
        let view = NSHostingView(rootView: LocalNoteWorkspaceView(session: session, store: owner.store,
            onNew: { [weak owner] in owner?.createNote() }, onRename: { [weak self] in self?.rename() },
            onExport: { [weak self] in self?.export() }, onRestore: { [weak owner] in owner?.restore($0) }, onOpen: { [weak owner] in owner?.openNote($0) }))
        view.sizingOptions = []; window.contentView = view
        observation = session.$record.sink { [weak window] record in
            window?.title = "\(record.title) — 便笺"; window?.level = record.isPinned ? .floating : .normal
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func createNoteWindow() { manager?.createNote() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { return true }
        guard !closing else { return false }
        closing = true
        Task { [weak self] in
            guard let self else { return }
            if await session.captureAndFlush(freeze: true) { approvedClose = true; sender.performClose(nil) }
            closing = false
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { manager?.didClose(session.record.id) }
    private func rename() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "命名便笺"; alert.informativeText = "留空时使用正文第一行作为标题。"
        let field = NSTextField(string: session.record.titleIsAutomatic ? "" : session.record.title)
        field.placeholderString = "自动使用正文第一行"; field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak session] result in
            if result == .alertFirstButtonReturn { session?.rename(field.stringValue) }
        }
        alert.window.initialFirstResponder = field
    }
    private func export() {
        Task { [weak self] in
            guard let self, let window, await session.captureAndFlush() else { return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = session.record.title.replacingOccurrences(of: "/", with: "-") + ".zip"
            guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("donts-note-\(UUID())", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let package = try session.store.exportMarkdown(session.record.id, content: session.draft, to: temporary.appendingPathComponent("便笺", isDirectory: true))
                let zip = temporary.appendingPathComponent("note.zip")
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--keepParent", package.path, zip.path]
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw LocalNoteBridgeError("导出压缩包失败。") }
                try Data(contentsOf: zip).write(to: destination, options: .atomic)
            } catch { session.fail(error.localizedDescription) }
        }
    }
}
