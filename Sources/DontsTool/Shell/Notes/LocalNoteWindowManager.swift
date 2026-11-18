import AppKit
import Combine
import DontsToolCore

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

    func flushOpenNotes() async {
        for controller in Array(controllers.values) where !controller.session.isTrashed {
            _ = await controller.session.captureAndFlush(freeze: false)
        }
    }

    func reconcileWithStore() {
        for (id, controller) in Array(controllers) {
            if controller.session.isTrashed {
                if !store.trashedNotes.contains(where: { $0.id == id }) {
                    controller.forceCloseWithoutFlush()
                }
            } else if let latest = store.note(id) {
                if latest.content != controller.session.record.content {
                    controller.session.syncExternalUpdate(latest)
                }
            } else {
                controller.forceCloseWithoutFlush()
            }
        }
    }

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
