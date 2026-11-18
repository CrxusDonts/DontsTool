import AppKit
import Combine
import DontsToolCore
import SwiftUI

@MainActor private final class KnowledgeWindowState: ObservableObject {
    @Published var pinned = false
    @Published var locked = false
}

@MainActor
final class KnowledgeWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    let id = UUID()
    let request: KnowledgeOpenRequest
    let bridge: KnowledgeWebBridge
    var onClose: (() -> Void)?
    private let viewState = KnowledgeWindowState()
    private let onSettings: () -> Void
    private var systemAppearanceObservation: NSKeyValueObservation?
    private var allowClose = false
    private var checkingClose = false
    private var checkingDeparture = false
    private var initialCaptureText: String?

    var acceptsLauncherRequests: Bool {
        guard !viewState.locked, !checkingClose, !checkingDeparture, bridge.isReady,
              let url = bridge.webView.url else { return false }
        return url.path == "/tool" && bridge.origin.contains(url)
    }

    init(origin: KnowledgeOrigin, request: KnowledgeOpenRequest, onSettings: @escaping () -> Void) {
        self.request = request
        self.onSettings = onSettings
        self.bridge = KnowledgeWebBridge(origin: origin, request: request)
        initialCaptureText = request.surface == .capture ? request.query : nil
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let desired = request.surface == .search || request.surface == .capture
            ? NSSize(width: 820, height: 600) : NSSize(width: 940, height: 680)
        let size = NSSize(width: min(desired.width, visible.width - 80), height: min(desired.height, visible.height - 80))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: min(700, size.width), height: min(480, size.height))
        window.backgroundColor = ToolTheme.shellNS; window.titlebarAppearsTransparent = true
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        switch request.surface {
        case .search: window.title = "知识库"
        case .editor: window.title = "文章 — 知识库"
        case .capture: window.title = "快速收集 — 知识库"
        case .inbox: window.title = "收集箱 — 知识库"
        }
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "KnowledgeWindowToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .unifiedCompact
        let content = NSHostingView(rootView: KnowledgeWindowRoot(bridge: bridge, state: viewState,
            onReload: { [weak self] in self?.reload() }, onSettings: onSettings))
        content.sizingOptions = []; window.contentView = content; window.delegate = self
        bridge.onTitle = { [weak window] title in window?.title = "\(title) — 知识库" }
        // Keep CSS prefers-color-scheme tied to the app/system, even when the
        // window chrome follows an explicit Web account theme.
        bridge.webView.appearance = NSApp.effectiveAppearance
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.bridge.webView.appearance = NSApp.effectiveAppearance }
        }
        bridge.onAppearance = { [weak window] scheme in
            window?.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
            window?.backgroundColor = Theme.hexColor(scheme == "dark" ? 0x1C1D1B : 0xF8F8F6)
        }
        bridge.onReady = { [weak self] in self?.deliverCapturePrefill() }
        bridge.onAuthChanged = { [weak self] in self?.deliverCapturePrefill() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func show() {
        NSApp.activate(ignoringOtherApps: true); window?.deminiaturize(nil)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    @objc private func togglePin() {
        guard !viewState.locked else { return }
        viewState.pinned.toggle(); window?.level = viewState.pinned ? .floating : .normal
        let pin = window?.toolbar?.items.first { $0.itemIdentifier == .knowledgePin }
        pin?.image = NSImage(systemSymbolName: viewState.pinned ? "pin.fill" : "pin", accessibilityDescription: "窗口置顶")
        pin?.toolTip = viewState.pinned ? "取消窗口置顶" : "窗口置顶"
    }
    @objc private func reconnect(_ sender: Any?) { reload() }
    @objc private func showSettings(_ sender: Any?) { if !viewState.locked { onSettings() } }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { !viewState.locked && !checkingDeparture }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .knowledgeReload, .knowledgePin, .knowledgeSettings]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let symbol: String
        switch identifier {
        case .knowledgeReload: item.label = "重新连接"; symbol = "arrow.clockwise"; item.action = #selector(reconnect(_:))
        case .knowledgePin: item.label = "窗口置顶"; symbol = "pin"; item.action = #selector(togglePin)
        case .knowledgeSettings: item.label = "设置"; symbol = "gearshape"; item.action = #selector(showSettings(_:))
        default: return nil
        }
        item.target = self; item.toolTip = item.label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        return item
    }
    private func deliverCapturePrefill() {
        guard let text = initialCaptureText, !text.isEmpty else { return }
        guard text.utf16.count <= 20_000 else {
            showError("带入的收集内容过长，尚未追加到草稿。请缩短内容后重新打开快速收集；关闭前会再次询问是否放弃这段内容。")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await bridge.request(["type": "prefillCapture", "text": text])
                let body = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
                if body?["applied"] as? Bool == true { initialCaptureText = nil }
            } catch { showError(error.localizedDescription) }
        }
    }
    /// Every destructive navigation asks the existing Web draft/save guards first.
    func prepareToClose(lock: Bool = false) async -> Bool {
        // An approved, frozen document cannot change before the ensuing system quit.
        if lock && viewState.locked { return true }
        guard !checkingDeparture else { return false }
        checkingDeparture = true
        defer { checkingDeparture = false }
        if let text = initialCaptureText, !text.isEmpty {
            guard let window else { return false }
            let alert = NSAlert(); alert.messageText = "收集内容尚未送入编辑器"
            alert.informativeText = "请先完成登录并等待内容加入草稿。要放弃从启动器带入的内容吗？"
            alert.addButton(withTitle: "继续收集"); alert.addButton(withTitle: "放弃内容")
            let answer = await alert.beginSheetModal(for: window)
            guard answer == .alertSecondButtonReturn else { return false }
        }
        if !bridge.hasBeenReady {
            if lock { viewState.locked = true; window?.makeFirstResponder(nil) }
            return true
        }
        guard bridge.isReady else { showError("页面尚未恢复连接，请重新连接后再关闭，以保护未保存内容。"); return false }
        do {
            let response = try await bridge.request(lock ? ["type": "prepareClose", "lock": true] : ["type": "prepareClose"], timeout: 45)
            let body = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
            let approved = body?["canClose"] as? Bool == true
            if approved && lock { viewState.locked = true; window?.makeFirstResponder(nil) }
            return approved
        } catch { showError(error.localizedDescription); return false }
    }
    func resumeInteraction() async {
        if bridge.isReady { _ = try? await bridge.request(["type": "resumeInteraction"]) }
        viewState.locked = false
    }
    private func reload() {
        guard !viewState.locked else { return }
        // Reconnect after a process/load failure: the Web client restores its own durable draft.
        if !bridge.isReady { bridge.reload(); return }
        Task { [weak self] in
            guard let self, await prepareToClose() else { return }
            bridge.reload()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !viewState.locked else { return false }
        if allowClose || (!bridge.hasBeenReady && initialCaptureText == nil) { return true }
        guard !checkingClose else { return false }
        checkingClose = true
        Task { [weak self] in
            guard let self else { return }
            let approved = await prepareToClose(); checkingClose = false
            if approved { allowClose = true; window?.performClose(nil) }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { bridge.stop(); onClose?() }
    private func showError(_ message: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "知识库"; alert.informativeText = message
        alert.addButton(withTitle: "好"); alert.beginSheetModal(for: window)
    }
}
private struct KnowledgeWindowRoot: View {
    @ObservedObject var bridge: KnowledgeWebBridge
    @ObservedObject var state: KnowledgeWindowState
    let onReload: () -> Void
    let onSettings: () -> Void
    var body: some View { KnowledgeWindowView(bridge: bridge, onReload: onReload, onSettings: onSettings, locked: state.locked) }
}

private extension NSToolbarItem.Identifier {
    static let knowledgeReload = Self("knowledge.reload")
    static let knowledgePin = Self("knowledge.pin")
    static let knowledgeSettings = Self("knowledge.settings")
}
