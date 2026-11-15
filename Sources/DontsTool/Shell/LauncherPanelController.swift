import AppKit
import DontsToolCore
import SwiftUI

/// 启动器面板的 AppKit 壳层：窗口行为、焦点、键盘路由与显隐动效。
/// 界面内容全部由 SwiftUI 的 LauncherPanelView 承载。
@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate, OperationProgressReporting {
    var onOpenSettings: (() -> Void)?
    var onRescanApps: (() -> Void)?

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
        installContent()
        wireSearchField()
    }

    func updateHotKeyDisplay(_ display: String) {
        model.updateHotKeyDisplay(display)
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
        let origin = panelOrigin()

        model.clearContent()
        searchField.stringValue = ""
        searchField.setContentMode(false)
        refreshSearch()
        isVisible = true
        transitionDriver.show(panel: panel, at: origin)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        Performance.end(interval)
    }

    func hide(restorePreviousApp: Bool = true) {
        guard isVisible else { return }
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

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        // The user already chose another window; dismissal must not override that choice.
        hide(restorePreviousApp: false)
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
            onShowActions: { [weak self] in self?.model.toggleActionPanel() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Metrics.panelSize)
        panel.contentView = hosting
    }

    private func wireSearchField() {
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
              let action = secondary ? item.secondaryAction : item.primaryAction else { return }
        execute(action)
    }

    private func execute(_ action: ItemAction) {
        model.closeActionPanel()
        switch action.presentation {
        case .openWindow:
            // Hide synchronously before activation; a delayed dismissal must not steal focus.
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
}
