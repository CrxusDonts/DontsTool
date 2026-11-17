import AppKit
import Combine
import DontsToolCore
import SwiftUI

@MainActor
final class ToolWindowManager: NSObject, ToolDocumentProviding {
    let store: ToolDocumentStore
    private var controllers: [UUID: ToolWindowController] = [:]
    private let settings: SettingsStore
    private let usage: UsageStore
    private var lastActive: UUID?
    private var cascadePoint = NSPoint.zero
    private var observation: AnyCancellable?
    var onOpenSettings: (() -> Void)?
    var onDocumentsChanged: (() -> Void)?
    var toolDocuments: [ToolDocument] { store.openDocuments }

    init(settings: SettingsStore, translator: TranslationServicing, usage: UsageStore) {
        self.settings = settings
        self.usage = usage
        store = ToolDocumentStore(translator: translator, translationTarget: settings.translationTarget)
        super.init()
        observation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.pruneClosedControllers(); self?.onDocumentsChanged?() }
        }
        installDocumentMenu()
    }
    func openTool(_ request: ToolOpenRequest) {
        let document = store.create(request)
        if document.kind == .translation { document.session.target = settings.translationTarget }
        show(document)
    }
    func activateDocument(_ id: UUID) {
        guard let document = store.openDocuments.first(where: { $0.id == id }) else { return }
        show(document)
    }
    private func show(_ document: ToolDocument) {
        let controller: ToolWindowController
        if let existing = controllers[document.id] { controller = existing }
        else {
            controller = ToolWindowController(document: document, store: store, owner: self)
            if cascadePoint == .zero { controller.window?.center() }
            else { _ = controller.window?.cascadeTopLeft(from: cascadePoint) }
            if let frame = controller.window?.frame { cascadePoint = NSPoint(x: frame.minX + 24, y: frame.maxY - 24) }
            controllers[document.id] = controller
        }
        guard let window = controller.window else { return }
        store.activate(document.id); lastActive = document.id
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
        usage.recordUse(of: document.kind.launcherKey)
    }
    func newWindow(kind: ToolKind) { openTool(ToolOpenRequest(kind: kind)) }
    func duplicate(_ id: UUID) { if let document = store.duplicate(id) { show(document) } }
    func reopen(_ id: UUID) { if let document = store.reopen(id) { show(document) } }
    func didActivate(_ document: ToolDocument) { lastActive = document.id; store.activate(document.id) }
    func didClose(_ document: ToolDocument) { store.close(document.id) }
    func openSettings() { onOpenSettings?() }
    func shutdown() { store.documents.forEach { $0.session.cancel() } }
    private func pruneClosedControllers() {
        let retained = Set(store.documents.map(\.id))
        for id in Array(controllers.keys) where !retained.contains(id) { controllers.removeValue(forKey: id) }
    }
    private var active: ToolDocument? {
        if let controller = NSApp.keyWindow?.windowController as? ToolWindowController { return controller.documentRecord }
        return store.openDocuments.first { $0.id == lastActive } ?? store.openDocuments.first
    }
    @objc private func newDocument(_ sender: Any?) {
        if let note = NSApp.keyWindow?.windowController as? any NativeNoteCreating { note.createNoteWindow() }
        else { newWindow(kind: active?.kind ?? .json) }
    }
    @objc private func duplicateDocument(_ sender: Any?) { if let active { duplicate(active.id) } }
    @objc private func reopenLastWindow(_ sender: Any?) { if let document = store.recentlyClosed.first { reopen(document.id) } }
    private func installDocumentMenu() {
        guard let main = NSApp.mainMenu else { return }
        let item = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "文件")
        let create = menu.addItem(withTitle: "新建工具窗口", action: #selector(newDocument(_:)), keyEquivalent: "n"); create.target = self
        menu.addItem(.separator())
        let reopen = menu.addItem(withTitle: "重新打开关闭的窗口", action: #selector(reopenLastWindow(_:)), keyEquivalent: "t")
        reopen.target = self; reopen.keyEquivalentModifierMask = [.command, .shift]
        item.submenu = menu; main.insertItem(item, at: min(1, main.items.count))
    }
}

@MainActor
private final class ToolWindowController: NSWindowController, NSWindowDelegate {
    let documentRecord: ToolDocument
    private let draftEditor: ToolDraftEditor
    private weak var windowManager: ToolWindowManager?
    private var titleObservation: AnyCancellable?
    private var pinObservation: AnyCancellable?
    init(document: ToolDocument, store: ToolDocumentStore, owner: ToolWindowManager) {
        self.documentRecord = document; self.windowManager = owner
        self.draftEditor = ToolDraftEditor(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.setContentSize(NSSize(width: 1040, height: 700))
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.backgroundColor = ToolTheme.shellNS
        window.titlebarAppearsTransparent = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        let content = NSHostingView(rootView: ToolWorkspaceView(document: document, documents: store, draftEditor: draftEditor,
            onOpenSettings: { [weak owner] in owner?.openSettings() }))
        // The window owns its size; editor fitting sizes must not expand it during mode changes.
        content.sizingOptions = []
        window.contentView = content
        super.init(window: window)
        window.delegate = self
        titleObservation = document.$title.sink { [weak window] title in window?.title = "\(title) — \(document.kind.title)" }
        pinObservation = document.$isPinned.sink { [weak window] pinned in
            window?.level = pinned ? .floating : .normal
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { draftEditor.undoManager }
    func windowWillClose(_ notification: Notification) { windowManager?.didClose(documentRecord) }
    func windowDidBecomeKey(_ notification: Notification) { windowManager?.didActivate(documentRecord) }
}
