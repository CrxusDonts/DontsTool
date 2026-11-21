import AppKit
import Combine
import DontsToolCore
import SwiftUI

/// 启动器面板的 AppKit 壳层：窗口行为、焦点、键盘路由与显隐动效。
/// 界面内容全部由 SwiftUI 的 LauncherPanelView 承载。
@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate, OperationProgressReporting {
    var onOpenSettings: (() -> Void)?
    var onRescanApps: (() -> Void)?
    var onDidShow: (() -> Void)?
    var onOpenUpdate: (() -> Void)?
    var onDismissUpdate: (() -> Void)?

    private let model: LauncherPanelModel
    private let registry: ToolRegistry
    private let settings: SettingsStore
    private let toast: FeedbackProviding
    private let panel: LauncherPanel
    private let searchField = SearchField()
    private let fieldEditor = LauncherFieldEditor()
    private let transitionDriver = PanelTransitionDriver()
    private var previousApp: NSRunningApplication?
    private var isVisible = false
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var layoutCancellable: AnyCancellable?
    private var heightUpdateScheduled = false

    isolated deinit {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }

    init(
        registry: ToolRegistry,
        coordinator: SearchCoordinator,
        toast: FeedbackProviding,
        hotKeyDisplay: String,
        settings: SettingsStore,
        contentProvider: ContentActionProvider
    ) {
        self.registry = registry
        self.settings = settings
        self.model = LauncherPanelModel(coordinator: coordinator, hotKeyDisplay: hotKeyDisplay, contentProvider: contentProvider)
        self.toast = toast
        panel = LauncherPanel(size: Metrics.panelSize)
        super.init()
        panel.delegate = self
        fieldEditor.isFieldEditor = true
        fieldEditor.onPasteContent = { [weak self] text in self?.receiveContent(text) ?? false }
        fieldEditor.onCompositionChange = { [weak self] marked, text in
            guard let self else { return }
            if marked { model.suspendSearchForComposition() }
            else {
                if searchField.stringValue != text { searchField.stringValue = text }
                refreshSearch()
            }
        }
        installContent()
        wireSearchField()
        observeLayoutChanges()
    }

    func updateHotKeyDisplay(_ display: String) {
        model.updateHotKeyDisplay(display)
    }

    func updateAvailableUpdateVersion(_ version: String?) {
        model.updateAvailableUpdateVersion(version)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }
        model.closeActionPanel()
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }
        let interval = Performance.begin("panel.show")
        model.clearContent()
        searchField.stringValue = ""
        searchField.setContentMode(false)
        updatePanelHeight()
        let origin = panelOrigin()

        refreshSearch()
        isVisible = true
        transitionDriver.show(panel: panel, at: origin)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        startMonitoringOutsideClicks()
        Performance.end(interval)
        DispatchQueue.main.async { [weak self] in
            self?.onDidShow?()
        }
    }

    func hide(restorePreviousApp: Bool = true) {
        guard isVisible else { return }
        stopMonitoringOutsideClicks()
        model.closeActionPanel()
        isVisible = false
        transitionDriver.hide(panel: panel) { [weak self] in
            guard let self, !self.isVisible else { return }
            let shouldRestore = restorePreviousApp && self.panel.isKeyWindow
            self.panel.orderOut(nil)
            self.model.clearContent()
            if shouldRestore {
                self.previousApp?.activate()
            }
            self.previousApp = nil
        }
    }

    func clearQuery() {
        searchField.stringValue = ""
        panel.makeFirstResponder(searchField)
        refreshSearch()
    }

    func refreshSearch() {
        guard !searchField.isComposing else { model.suspendSearchForComposition(); return }
        let query = searchField.stringValue
        model.updateQueryText(query)
        model.updateQueryRoute(model.attachedContent == nil ? keywordRoute(for: query) : nil)
        model.submit(query, frontmostBundleID: previousApp?.bundleIdentifier)
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? SearchField) === searchField ? fieldEditor : nil
    }

    private func receiveContent(_ text: String) -> Bool {
        guard text.utf8.count <= ToolOperations.textByteLimit else {
            model.showToast("内容过大，请直接在工具窗口中打开")
            return true
        }
        guard model.attachContent(text) else { return false }
        searchField.stringValue = ""
        searchField.setContentMode(true)
        return true
    }

    private func clearContent() {
        model.clearContent()
        searchField.setContentMode(false)
        clearQuery()
    }

    private func startMonitoringOutsideClicks() {
        stopMonitoringOutsideClicks()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.hide(restorePreviousApp: false)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel {
                self.hide(restorePreviousApp: false)
            }
            return event
        }
    }

    private func stopMonitoringOutsideClicks() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    // MARK: 进度（翻译等长任务）

    func begin(_ message: String) {
        model.beginProgress(message)
    }

    func end() {
        model.endProgress()
    }

    // MARK: 内部

    private func installContent() {
        let view = LauncherPanelView(
            model: model,
            searchField: searchField,
            settings: settings,
            onOpenSettings: { [weak self] in
                guard let self else { return }
                self.hide(restorePreviousApp: false)
                self.onOpenSettings?()
            },
            onExecute: { [weak self] index, secondary in
                self?.execute(at: index, secondary: secondary)
            },
            onExecuteAction: { [weak self] index in
                self?.executeAction(at: index)
            },
            onClearQuery: { [weak self] in
                self?.clearQuery()
            },
            onClearContent: { [weak self] in self?.clearContent() },
            onShowActions: { [weak self] in self?.model.toggleActionPanel() },
            onCopyFilePath: { [weak self] index in _ = self?.copyFilePath(at: index) },
            onOpenUpdate: { [weak self] in
                guard let self else { return }
                self.hide(restorePreviousApp: false)
                self.onOpenUpdate?()
            },
            onDismissUpdate: { [weak self] in
                self?.onDismissUpdate?()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = hosting
    }

    private func observeLayoutChanges() {
        layoutCancellable = model.objectWillChange.sink { [weak self] _ in
            guard let self, !self.heightUpdateScheduled else { return }
            self.heightUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightUpdateScheduled = false
                self.updatePanelHeight()
            }
        }
    }

    private func updatePanelHeight() {
        let targetHeight = LauncherPanelLayout.preferredHeight(for: model, currentHeight: panel.frame.height)
        let currentFrame = panel.frame
        let deltaHeight = targetHeight - currentFrame.height
        guard abs(deltaHeight) >= 1 else { return }
        // 保持顶部边缘（maxY）固定，面板仅向下伸缩，避免搜索框上下跳动。
        let deltaY = -deltaHeight
        let nextFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + deltaY,
            width: Metrics.panelSize.width,
            height: targetHeight
        )
        transitionDriver.adjustOrigin(deltaY: deltaY)
        panel.setFrame(nextFrame, display: true, animate: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: nextFrame.size)
    }

    private func wireSearchField() {
        searchField.onCompositionBegin = { [weak self] in self?.model.suspendSearchForComposition() }
        searchField.onTextChange = { [weak self] _ in self?.refreshSearch() }
        searchField.onMoveUp = { [weak self] in
            guard let self else { return }
            if self.model.isActionPanelOpen {
                self.model.moveActionSelection(by: -1)
            } else {
                self.model.moveSelection(by: -1)
            }
        }
        searchField.onMoveDown = { [weak self] in
            guard let self else { return }
            if self.model.isActionPanelOpen {
                self.model.moveActionSelection(by: 1)
            } else {
                self.model.moveSelection(by: 1)
            }
        }
        searchField.onConfirm = { [weak self] in
            guard let self else { return }
            if self.model.isActionPanelOpen {
                self.executeSelectedAction()
            } else {
                self.executeSelected(secondary: false)
            }
        }
        searchField.onSecondaryConfirm = { [weak self] in
            guard let self else { return }
            if self.model.isActionPanelOpen {
                self.executeSelectedAction()
            } else {
                self.executeSelected(secondary: true)
            }
        }
        searchField.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.isActionPanelOpen {
                self.model.closeActionPanel()
            } else if self.model.attachedContent != nil {
                if self.searchField.stringValue.isEmpty { self.clearContent() }
                else { self.clearQuery() }
            } else {
                self.hide()
            }
        }
        searchField.onOpenSettings = { [weak self] in
            guard let self else { return }
            self.hide(restorePreviousApp: false)
            self.onOpenSettings?()
        }
        searchField.onRescan = { [weak self] in self?.onRescanApps?() }
        searchField.onShowActions = { [weak self] in self?.model.toggleActionPanel() }
        searchField.onCopyFilePath = { [weak self] in
            guard let self, !self.model.isActionPanelOpen else { return false }
            return self.copyFilePath(at: self.model.selectedIndex)
        }
    }

    private func keywordRoute(for query: String) -> KeywordRoute? {
        let routes = registry.enabledKeywordRoutes()
        let context = QueryParser.parse(query, routes: routes, frontmostBundleID: nil)
        if case .keyword(let providerID, let keyword, _) = context.mode {
            return KeywordRoute(providerID: providerID, keyword: keyword)
        }
        return nil
    }

    private func executeSelected(secondary: Bool) {
        execute(at: model.selectedIndex, secondary: secondary)
    }

    private func executeSelectedAction() {
        guard let action = model.selectedAction else { return }
        execute(action)
    }

    private func executeAction(at index: Int) {
        model.selectAction(index: index)
        guard let action = model.selectedAction else { return }
        execute(action)
    }

    private func execute(at index: Int, secondary: Bool) {
        guard let item = model.item(at: index),
              let action = secondary ? (item.fileAction(.reveal) ?? item.secondaryAction) : item.primaryAction else { return }
        execute(action)
    }

    private func copyFilePath(at index: Int) -> Bool {
        guard let action = model.item(at: index)?.fileAction(.copyPath) else { return false }
        execute(action)
        return true
    }

    private func execute(_ action: ItemAction) {
        model.closeActionPanel()
        switch action.presentation {
        case .openWindow:
            // Hide synchronously before activation; a delayed dismissal must not steal focus.
            stopMonitoringOutsideClicks()
            isVisible = false
            transitionDriver.cancel()
            panel.orderOut(nil)
            model.clearContent()
            previousApp = nil
            run(action)
        case .dismissThenRun:
            hide(restorePreviousApp: false)
            run(action)
        case .keepPanelUntilComplete:
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await action.run()
                    self.hide()
                } catch {
                    self.toast.show(error.localizedDescription)
                }
            }
        case .keepPanelOpen:
            run(action)
        }
    }

    private func run(_ action: ItemAction) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await action.run()
            } catch {
                self.toast.show(error.localizedDescription)
            }
        }
    }

    private func panelOrigin() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return panel.frame.origin }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * 0.18 - size.height
        )
        return origin
    }

}

extension LauncherPanelController: QueryPrefilling {
    func prefill(_ query: String) {
        searchField.stringValue = query
        panel.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: query.utf16.count, length: 0)
        }
        refreshSearch()
    }

    func showAndPrefill(_ query: String) {
        if !isVisible {
            show()
        } else {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
        prefill(query)
    }
}
