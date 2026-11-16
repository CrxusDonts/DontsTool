import AppKit
import ApplicationServices
import Combine
import DontsToolCore
import SwiftUI

@MainActor
final class SelectionTranslationController: ObservableObject {
    @Published private(set) var holdDelayLabel = "2 秒"
    @Published private(set) var status = "未开启"
    @Published private(set) var lastGestureDiagnostic = "尚未收到右键操作"
    @Published var pinned = false
    @Published private(set) var copied = false
    @Published private(set) var selectionFailure: String?
    @Published private(set) var selectionReadInProgress = false
    @Published private(set) var gestureVerificationShown = false
    let session: ToolSession
    var onOpenSettings: (() -> Void)?
    var onEditSource: ((String) -> Void)?
    private let settings: SettingsStore
    private let monitor: RightPressMonitor
    private var panel: NSPanel?
    private var settingObservation: AnyCancellable?
    private var activationObservation: AnyCancellable?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var escapeMonitor: Any?
    private var copyTask: Task<Void, Never>?
    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    init(settings: SettingsStore, translator: TranslationServicing, monitor: RightPressMonitor = RightPressMonitor(),
         gestureVerificationOnly: Bool = false) {
        self.settings = settings
        self.monitor = monitor
        session = ToolSession(kind: .translation, translator: translator)
        monitor.onReading = { [weak self] point in self?.showReading(at: point) }
        monitor.onSelectionFailure = { [weak self] message, point in self?.showSelectionFailure(message, at: point) }
        monitor.onTranslate = { [weak self] text, point in self?.show(text: text, at: point) }
        monitor.ignoresPoint = { [weak self] point in self?.contains(point) == true }
        monitor.onFailure = { [weak self] in self?.status = "鼠标监听已暂停，请关闭后重新开启" }
        monitor.onDiagnostic = { [weak self] in self?.lastGestureDiagnostic = $0 }
        if gestureVerificationOnly {
            monitor.onHold = { [weak self] _, point in self?.showGestureVerification(at: point) }
        }
        settingObservation = settings.$selectionTranslationEnabled.combineLatest(settings.$selectionHoldDelay).dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        activationObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.dismissForApplicationChange()
                }
            }
        refresh()
    }

    func refresh() {
        holdDelayLabel = settings.selectionHoldDelay.label
        monitor.setHoldDelay(settings.selectionHoldDelay)
        guard settings.selectionTranslationEnabled else {
            monitor.stop(); dismiss(); status = "未开启"; return
        }
        guard accessibilityGranted else {
            monitor.stop(); dismiss(); status = "需要辅助功能授权，授权后返回即可生效"; return
        }
        status = monitor.start() ? "已开启 · 双指停留或右键长按 \(holdDelayLabel)" : "无法启动鼠标监听，请检查系统授权后重试"
    }

    func requestAccessibility() {
        // The documented kAXTrustedCheckOptionPrompt value; the C global is imported
        // as shared mutable state under Swift 6 despite its constant string contents.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    func show(text: String, at point: CGPoint) {
        gestureVerificationShown = false
        selectionFailure = nil
        selectionReadInProgress = false
        prepareCard(text: text, at: point)
        session.run()
    }

    func showReading(at point: CGPoint) {
        gestureVerificationShown = false
        selectionFailure = nil
        selectionReadInProgress = true
        prepareCard(text: "", at: point)
    }

    func showSelectionFailure(_ message: String, at point: CGPoint) {
        gestureVerificationShown = false
        selectionReadInProgress = false
        selectionFailure = message
        prepareCard(text: "", at: point)
    }

    func showGestureVerification(at point: CGPoint) {
        gestureVerificationShown = true
        selectionFailure = nil
        selectionReadInProgress = false
        prepareCard(text: "", at: point)
    }

    private func prepareCard(text: String, at point: CGPoint) {
        session.cancel()
        session.input = text
        session.target = settings.translationTarget
        copied = false; copyTask?.cancel()
        if panel == nil {
            let panel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 330),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: SelectionTranslationView(controller: self, session: session))
            self.panel = panel
        }
        guard let panel else { return }
        let anchor = Self.appKitPoint(point)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let bounds = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 8, dy: 8)
        let x = min(max(anchor.x + 14, bounds.minX), bounds.maxX - panel.frame.width)
        let below = anchor.y - panel.frame.height - 16
        let y = min(max(below < bounds.minY ? anchor.y + 20 : below, bounds.minY), bounds.maxY - panel.frame.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // Preserve the source app's focus and selection; no NSApp.activate here.
        let entering = !panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = entering ? 0 : 1
        panel.orderFrontRegardless()
        if entering {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
        installDismissalMonitors()
    }

    func dismiss() {
        monitor.cancelPendingReading()
        selectionReadInProgress = false
        panel?.orderOut(nil)
        session.cancel()
        for token in [outsideMonitor, localMonitor, escapeMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(token) }
        outsideMonitor = nil; localMonitor = nil; escapeMonitor = nil
    }

    func dismissForApplicationChange() {
        if !pinned, panel?.isVisible == true { dismiss() }
    }

    func copyTranslation() {
        guard session.canCopy else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.output, forType: .string)
        copied = true
        copyTask?.cancel()
        copyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func editSource() {
        let text = session.input
        dismiss()
        onEditSource?(text)
    }

    func openSettings() { dismiss(); onOpenSettings?() }

    func shutdown() {
        monitor.stop(); dismiss(); copyTask?.cancel()
        settingObservation?.cancel(); activationObservation?.cancel()
        // The hosting view observes this controller; release it to break the window cycle.
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    private func installDismissalMonitors() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pinned, self.panel?.frame.contains(NSEvent.mouseLocation) == false else { return }
                self.dismiss()
            }
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.dismiss() } }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let forward = MainActor.assumeIsolated {
                guard let self else { return true }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.dismiss(); return false
                }
                if event.type != .keyDown, event.window !== self.panel, !self.pinned { self.dismiss() }
                return true
            }
            return forward ? event : nil
        }
    }

    private func contains(_ point: CGPoint) -> Bool {
        panel?.isVisible == true && panel?.frame.contains(Self.appKitPoint(point)) == true
    }

    private static func appKitPoint(_ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }
}

private final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
