import Combine
import DontsToolCore
import Foundation
import os

@MainActor
final class HotKeyBindingCoordinator {
    private let settings: SettingsStore
    private let toast: FeedbackProviding
    private let hotKeyManager = HotKeyManager()
    private let doubleTapMonitor = ModifierDoubleTapMonitor()
    private var hotKeyCancellable: AnyCancellable?
    private var activeHotKey: SettingsStore.HotKeyConfiguration?
    private var isRecordingHotKey = false
    private var onToggle: (() -> Void)?
    private var onDisplayChanged: ((String) -> Void)?

    init(settings: SettingsStore, toast: FeedbackProviding) {
        self.settings = settings
        self.toast = toast
    }

    func start(
        onToggle: @escaping () -> Void,
        onDisplayChanged: @escaping (String) -> Void
    ) {
        self.onToggle = onToggle
        self.onDisplayChanged = onDisplayChanged
        hotKeyManager.onHotKey = onToggle
        hotKeyCancellable = settings.hotKeyChanges
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] configuration in
                guard let self else { return }
                if self.isRecordingHotKey {
                    self.updateDisplay(configuration)
                } else if configuration == self.activeHotKey {
                    self.updateDisplay(configuration)
                } else {
                    self.apply(configuration)
                }
            }
        apply(settings.hotKey)
    }

    func stop() {
        hotKeyCancellable?.cancel()
        hotKeyCancellable = nil
        doubleTapMonitor.stop()
    }

    func setRecording(_ isRecording: Bool) {
        isRecordingHotKey = isRecording
        if isRecording {
            hotKeyManager.unregister()
            doubleTapMonitor.stop()
        } else {
            apply(settings.hotKey)
        }
    }

    func apply(_ configuration: SettingsStore.HotKeyConfiguration) {
        hotKeyManager.unregister()
        doubleTapMonitor.stop()

        switch configuration.kind {
        case .doubleTap:
            guard let modifier = configuration.doubleTapModifier else {
                activeHotKey = nil
                updateDisplay(configuration)
                toast.show("无效的双击快捷键配置")
                return
            }
            let previous = activeHotKey
            let started = doubleTapMonitor.start(modifier: modifier) { [weak self] in
                self?.onToggle?()
            }
            if started {
                activeHotKey = configuration
            } else {
                activeHotKey = nil
                // 监听创建失败时保留一个可用的组合键，避免把用户锁在应用外。
                let fallback = (previous?.kind == .combination ? previous : nil) ?? .optionSpace
                if restore(fallback) {
                    activeHotKey = fallback
                    Log.app.error("双击热键监听启动失败")
                    toast.show("双击快捷键启动失败，暂时使用 \(HotKeyFormatter.displayString(for: fallback))")
                } else {
                    Log.app.error("双击热键监听启动失败且无可用回退")
                    toast.show("无法启动双击快捷键监听")
                }
            }
            updateDisplay(configuration)

        case .combination:
            do {
                try hotKeyManager.register(configuration)
                activeHotKey = configuration
                updateDisplay(configuration)
            } catch {
                Log.app.error("全局热键注册失败: \(error.localizedDescription, privacy: .public)")
                if let fallback = activeHotKey, restore(fallback) {
                    activeHotKey = fallback
                    // @Published 在 willSet 阶段发值，settings.hotKey 此时仍是旧值；
                    // 不能用它判断是否需要回退，否则会把冲突组合留在持久化存储里。
                    settings.setHotKey(fallback)
                    updateDisplay(fallback)
                } else {
                    activeHotKey = nil
                    updateDisplay(configuration)
                }
                toast.show(error.localizedDescription)
            }
        }
    }

    private func restore(_ configuration: SettingsStore.HotKeyConfiguration) -> Bool {
        switch configuration.kind {
        case .combination:
            do {
                try hotKeyManager.register(configuration)
                return true
            } catch {
                return false
            }
        case .doubleTap:
            guard let modifier = configuration.doubleTapModifier else { return false }
            return doubleTapMonitor.start(modifier: modifier) { [weak self] in
                self?.onToggle?()
            }
        }
    }

    private func updateDisplay(_ configuration: SettingsStore.HotKeyConfiguration) {
        onDisplayChanged?(HotKeyFormatter.displayString(for: configuration))
    }
}
