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
    private let toast: FeedbackProviding
    private let panel: LauncherPanel
    private let searchField = SearchField()
    private var previousApp: NSRunningApplication?
    private var isVisible = false

    init(
        registry: ToolRegistry,
        coordinator: SearchCoordinator,
        toast: FeedbackProviding,
        hotKeyDisplay: String
    ) {
        self.registry = registry
        self.model = LauncherPanelModel(coordinator: coordinator, hotKeyDisplay: hotKeyDisplay)
        self.toast = toast
        panel = LauncherPanel(size: Metrics.panelSize)
        super.init()
        panel.delegate = self
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
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }
        let interval = Performance.begin("panel.show")
        positionPanel()

        searchField.stringValue = ""
        refreshSearch()
        isVisible = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        animateAppearance()
        Performance.end(interval)
    }

    func hide(restorePreviousApp: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        animateDismissal { [weak self] in
            guard let self, !self.isVisible else { return }
            let shouldRestore = restorePreviousApp && self.panel.isKeyWindow
            self.panel.orderOut(nil)
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
        model.updateBadge(keywordBadge(for: query))
        model.submit(query, frontmostBundleID: previousApp?.bundleIdentifier)
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
            onOpenSettings: { [weak self] in
                guard let self else { return }
                self.hide(restorePreviousApp: false)
                self.onOpenSettings?()
            },
            onExecute: { [weak self] index, secondary in
                self?.execute(at: index, secondary: secondary)
            },
            onClearQuery: { [weak self] in
                self?.clearQuery()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Metrics.panelSize)
        panel.contentView = hosting
    }

    private func wireSearchField() {
        searchField.onTextChange = { [weak self] _ in self?.refreshSearch() }
        searchField.onMoveUp = { [weak self] in self?.model.moveSelection(by: -1) }
        searchField.onMoveDown = { [weak self] in self?.model.moveSelection(by: 1) }
        searchField.onConfirm = { [weak self] in self?.executeSelected(secondary: false) }
        searchField.onSecondaryConfirm = { [weak self] in self?.executeSelected(secondary: true) }
        searchField.onCancel = { [weak self] in self?.hide() }
        searchField.onOpenSettings = { [weak self] in
            guard let self else { return }
            self.hide(restorePreviousApp: false)
            self.onOpenSettings?()
        }
        searchField.onRescan = { [weak self] in self?.onRescanApps?() }
    }

    private func keywordBadge(for query: String) -> String? {
        let routes = registry.enabledKeywordRoutes()
        let context = QueryParser.parse(query, routes: routes, frontmostBundleID: nil)
        if case .keyword(_, let keyword, _) = context.mode {
            return keyword
        }
        return nil
    }

    private func executeSelected(secondary: Bool) {
        execute(at: model.selectedIndex, secondary: secondary)
    }

    private func execute(at index: Int, secondary: Bool) {
        guard let item = model.item(at: index),
              let action = secondary ? item.secondaryAction : item.primaryAction else { return }
        switch action.presentation {
        case .openWindow:
            // Hide synchronously before activation; a delayed dismissal must not steal focus.
            isVisible = false
            panel.orderOut(nil)
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

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * 0.18 - size.height
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: 动效（design/MOTION.md）

    private func animateAppearance() {
        guard !Motion.reduceMotion else {
            panel.alphaValue = 1
            return
        }
        // 只改窗口透明度：直接改 contentView.layer 的 anchorPoint/transform 会让
        // SwiftUI 图层位移并被裁掉（曾导致面板只剩空白与零星胶囊）。
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.panelEnter
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
        }
    }

    private func animateDismissal(completion: @escaping @MainActor @Sendable () -> Void) {
        guard !Motion.reduceMotion else {
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.panelExit
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in completion() }
        })
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
