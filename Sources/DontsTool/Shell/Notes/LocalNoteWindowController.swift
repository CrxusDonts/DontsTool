import AppKit
import Combine
import DontsToolCore
import SwiftUI
import UniformTypeIdentifiers

/// 单个本地便笺窗口控制器：管理窗口样式、SwiftUI 工作区装配、关闭确认与 Markdown 压缩包导出。
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

    func forceCloseWithoutFlush() {
        approvedClose = true
        window?.close()
    }

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
