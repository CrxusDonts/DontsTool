import AppKit
import Combine
import DontsToolCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol NativeNoteCreating: AnyObject { func createNoteWindow() }

@MainActor
final class LocalNoteWindowState: ObservableObject {
    @Published var session: LocalNoteSession
    @Published var isSidebarVisible = true
    @Published var isWindowFloating = false
    @Published var sidebarQuery = ""
    @Published var showingTrash = false
    @Published var previewingTrashedID: UUID?

    init(session: LocalNoteSession) {
        self.session = session
    }
}

@MainActor
final class LocalNoteWindowManager: LocalNoteOpening {
    let store: LocalNoteStore
    private(set) var controllers: [UUID: LocalNoteWindowController] = [:]
    private var cascadePoint = NSPoint.zero
    private let resourcesURL: URL?

    init(store: LocalNoteStore, resourcesURL: URL? = nil) {
        self.store = store
        self.resourcesURL = resourcesURL
    }

    var hasOpenWindows: Bool { !controllers.isEmpty }

    func createNote() {
        do { open(try store.create()) } catch { showError(error.localizedDescription) }
    }

    func createNote(with text: String) {
        do {
            let record = try store.create(content: LocalNoteContent.plainText(text))
            open(record)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @discardableResult
    func quickCapture(_ text: String) throws -> LocalNoteRecord {
        let dailyTitle = LocalNoteStore.dailyNoteTitle()
        if let existing = controllers.values.first(where: {
            !$0.session.isTrashed && !$0.session.record.titleIsAutomatic && $0.session.record.title == dailyTitle
        }) {
            _ = existing.session.flush()
        }
        let record = try store.appendQuickCapture(text)
        if let openController = controllers[record.id] {
            openController.session.syncExternalUpdate(record)
        }
        return record
    }

    func openNote(_ id: UUID) {
        guard let record = store.note(id) else { return }
        open(record)
    }

    private func open(_ record: LocalNoteRecord) {
        let controller: LocalNoteWindowController
        if let existing = controllers[record.id] {
            controller = existing
        } else {
            controller = LocalNoteWindowController(
                session: LocalNoteSession(record: record, store: store, resourcesURL: resourcesURL),
                owner: self
            )
            controllers[record.id] = controller
            if cascadePoint == .zero { controller.window?.center() }
            else { _ = controller.window?.cascadeTopLeft(from: cascadePoint) }
            if let frame = controller.window?.frame { cascadePoint = NSPoint(x: frame.minX + 24, y: frame.maxY - 24) }
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.deminiaturize(nil)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func selectNote(_ id: UUID, in controller: LocalNoteWindowController) async {
        if controller.session.record.id == id {
            controller.state.showingTrash = false
            controller.state.previewingTrashedID = nil
            controller.window?.makeFirstResponder(controller.session.bridge.webView)
            controller.session.bridge.focus()
            return
        }
        if let existing = controllers[id], existing !== controller {
            existing.window?.deminiaturize(nil)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let oldID = controller.session.record.id
        guard await controller.session.captureAndFlush(freeze: true) else { return }
        guard let target = store.note(id) else {
            controller.session.bridge.setEditable(true)
            return
        }
        controllers.removeValue(forKey: oldID)
        let next = LocalNoteSession(record: target, store: store, resourcesURL: resourcesURL)
        controllers[id] = controller
        controller.replaceSession(next)
    }

    func createNoteInWorkspace(_ controller: LocalNoteWindowController) async {
        let oldID = controller.session.record.id
        guard await controller.session.captureAndFlush(freeze: true) else { return }
        do {
            let record = try store.create()
            controllers.removeValue(forKey: oldID)
            let next = LocalNoteSession(record: record, store: store, resourcesURL: resourcesURL)
            controllers[record.id] = controller
            controller.replaceSession(next)
        } catch {
            controller.session.bridge.setEditable(true)
            showError(error.localizedDescription)
        }
    }

    func trashNoteFromWorkspace(_ id: UUID, in controller: LocalNoteWindowController) async {
        if id == controller.session.record.id {
            let fallback = store.notes.first { $0.id != id && controllers[$0.id] == nil }
            guard await controller.session.trash() else { return }
            if let fallback {
                controllers.removeValue(forKey: id)
                let next = LocalNoteSession(record: fallback, store: store, resourcesURL: resourcesURL)
                controllers[fallback.id] = controller
                controller.replaceSession(next)
            }
        } else if let other = controllers[id] {
            _ = await other.session.trash()
        } else {
            do { try store.trash(id) } catch { showError(error.localizedDescription) }
        }
    }

    func restore(_ id: UUID) {
        if let controller = controllers[id] {
            controller.session.restore()
            openNote(id)
        } else {
            do { open(try store.restore(id)) } catch { showError(error.localizedDescription) }
        }
    }

    func restoreInWorkspace(_ id: UUID, in controller: LocalNoteWindowController) async {
        if let existing = controllers[id] {
            existing.session.restore()
            if existing === controller {
                controller.state.showingTrash = false
                controller.state.previewingTrashedID = nil
            } else {
                existing.window?.deminiaturize(nil)
                existing.showWindow(nil)
                existing.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        let oldID = controller.session.record.id
        guard await controller.session.captureAndFlush(freeze: true) else { return }
        do {
            let restored = try store.restore(id)
            controllers.removeValue(forKey: oldID)
            let next = LocalNoteSession(record: restored, store: store, resourcesURL: resourcesURL)
            controllers[restored.id] = controller
            controller.replaceSession(next)
        } catch {
            controller.session.bridge.setEditable(true)
            showError(error.localizedDescription)
        }
    }

    func deletePermanently(_ id: UUID, in controller: LocalNoteWindowController) {
        do {
            try store.deletePermanently(id)
            if controller.state.previewingTrashedID == id {
                controller.state.previewingTrashedID = store.trashedNotes.first?.id
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func emptyTrash(in controller: LocalNoteWindowController) {
        for id in store.trashedNotes.map(\.id) {
            do { try store.deletePermanently(id) }
            catch {
                showError(error.localizedDescription)
                break
            }
        }
        controller.state.previewingTrashedID = store.trashedNotes.first?.id
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

    func resumeEditing() {
        controllers.values.filter { !$0.session.isTrashed }.forEach { $0.session.bridge.setEditable(true) }
    }

    func shutdown() { controllers.values.forEach { $0.session.stop() } }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "便笺操作未完成"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

@MainActor
final class LocalNoteWindowController: NSWindowController, NSWindowDelegate, NativeNoteCreating {
    let state: LocalNoteWindowState
    var session: LocalNoteSession { state.session }
    private weak var manager: LocalNoteWindowManager?
    private var titleObservation: AnyCancellable?
    private var floatingObservation: AnyCancellable?
    private var closing = false
    private var approvedClose = false

    private static let expandedMinSize = NSSize(width: 640, height: 420)
    private static let collapsedMinSize = NSSize(width: 340, height: 380)
    private static let sidebarWidth: CGFloat = 220

    init(session: LocalNoteSession, owner: LocalNoteWindowManager) {
        self.state = LocalNoteWindowState(session: session)
        self.manager = owner
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = Self.expandedMinSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ToolTheme.shellNS
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self

        wireSession(session)
        floatingObservation = state.$isWindowFloating.sink { [weak window] floating in
            window?.level = floating ? .floating : .normal
        }

        let view = NSHostingView(rootView: LocalNoteWorkspaceView(
            state: state,
            store: owner.store,
            onSelect: { [weak self, weak owner] id in
                guard let self, let owner else { return }
                Task { await owner.selectNote(id, in: self) }
            },
            onCreateInWorkspace: { [weak self, weak owner] in
                guard let self, let owner else { return }
                Task { await owner.createNoteInWorkspace(self) }
            },
            onNewWindow: { [weak owner] in owner?.createNote() },
            onToggleSidebar: { [weak self] in self?.toggleSidebar() },
            onExport: { [weak self] in self?.export() },
            onTrash: { [weak self, weak owner] id in
                guard let self, let owner else { return }
                Task { await owner.trashNoteFromWorkspace(id, in: self) }
            },
            onRestore: { [weak self, weak owner] id in
                guard let self, let owner else { return }
                Task { await owner.restoreInWorkspace(id, in: self) }
            },
            onDeletePermanently: { [weak self, weak owner] id in
                guard let self, let owner else { return }
                owner.deletePermanently(id, in: self)
            },
            onEmptyTrash: { [weak self, weak owner] in
                guard let self, let owner else { return }
                owner.emptyTrash(in: self)
            },
            onOpenWindow: { [weak owner] id in owner?.openNote(id) }
        ))
        view.sizingOptions = []
        window.contentView = view
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func replaceSession(_ next: LocalNoteSession) {
        let old = state.session
        state.session = next
        state.showingTrash = false
        state.previewingTrashedID = nil
        old.stop()
        wireSession(next)
        if window?.isKeyWindow == true {
            window?.makeFirstResponder(next.bridge.webView)
            next.bridge.focus()
        }
    }

    func toggleSidebar() {
        let nextVisible = !state.isSidebarVisible
        state.isSidebarVisible = nextVisible
        guard let window else { return }
        window.contentMinSize = nextVisible ? Self.expandedMinSize : Self.collapsedMinSize
        var frame = window.frame
        if nextVisible {
            let targetWidth = max(760, frame.width + Self.sidebarWidth)
            let maxAvailable = window.screen?.visibleFrame.width ?? targetWidth
            frame.size.width = min(targetWidth, maxAvailable)
            if let visible = window.screen?.visibleFrame, frame.maxX > visible.maxX {
                frame.origin.x = max(visible.minX, visible.maxX - frame.width)
            }
        } else if frame.width >= 600 {
            frame.size.width = max(360, frame.width - Self.sidebarWidth)
        }
        window.setFrame(frame, display: true, animate: !Motion.reduceMotion)
    }

    private func wireSession(_ session: LocalNoteSession) {
        session.bridge.onReady = { [weak window, weak bridge = session.bridge] in
            if window?.isKeyWindow == true, let bridge {
                window?.makeFirstResponder(bridge.webView)
                bridge.focus()
            }
        }
        titleObservation = session.$record.sink { [weak window] record in
            window?.title = "\(record.title) — 便笺"
        }
    }

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
