import AppKit
import Combine
import DontsToolCore

@MainActor
final class MenuBarController: NSObject {
    weak var updates: AppUpdateController? {
        didSet { bindUpdates() }
    }
    weak var cloudSync: CloudSyncCoordinator? {
        didSet { bindCloudSync() }
    }
    var onOpenLauncher: (() -> Void)?
    var onOpenGuide: (() -> Void)?
    var onOpenSync: (() -> Void)?
    var onQuit: (() -> Void)?
    var hotKeyDisplay = "⌥Space" {
        didSet { refreshToolTip() }
    }

    private var statusItem: NSStatusItem?
    private var updateMenuItem: NSMenuItem?
    private var syncConflictMenuItem: NSMenuItem?
    private var availableUpdateVersion: String?
    private var pendingConflictCount = 0
    private var updateCancellable: AnyCancellable?
    private var syncConflictCancellable: AnyCancellable?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "d.square", accessibilityDescription: "DontsTool")
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("DontsTool")
        item.autosaveName = "DontsToolStatusItem"

        let menu = NSMenu()
        let open = NSMenuItem(title: "打开启动器", action: #selector(openLauncher), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let guide = NSMenuItem(title: "使用指南", action: #selector(openGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        let update = NSMenuItem(title: "检查更新…", action: #selector(AppUpdateController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updates
        menu.addItem(update)
        updateMenuItem = update
        let conflictItem = NSMenuItem(title: "同步冲突待处理…", action: #selector(openSync), keyEquivalent: "")
        conflictItem.target = self
        conflictItem.isHidden = true
        menu.addItem(conflictItem)
        syncConflictMenuItem = conflictItem
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 DontsTool", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        bindUpdates()
        bindCloudSync()
        refreshToolTip()
    }

    private func bindUpdates() {
        updateCancellable?.cancel()
        updateCancellable = updates?.$availableUpdateVersion
            .sink { [weak self] version in
                guard let self else { return }
                self.availableUpdateVersion = version
                self.updateMenuItem?.title = version.map { "有新版本 \($0)…" } ?? "检查更新…"
                self.refreshToolTip()
            }
    }

    private func bindCloudSync() {
        syncConflictCancellable?.cancel()
        syncConflictCancellable = cloudSync?.$pendingConflicts
            .sink { [weak self] conflicts in
                guard let self else { return }
                self.pendingConflictCount = conflicts.count
                if conflicts.isEmpty {
                    self.syncConflictMenuItem?.isHidden = true
                } else {
                    self.syncConflictMenuItem?.title = "同步冲突待处理 (\(conflicts.count))…"
                    self.syncConflictMenuItem?.isHidden = false
                }
                self.refreshToolTip()
            }
    }

    private func refreshToolTip() {
        var parts = ["DontsTool（\(hotKeyDisplay)）"]
        if pendingConflictCount > 0 {
            parts.append("\(pendingConflictCount) 项同步冲突待处理")
        }
        if let availableUpdateVersion {
            parts.append("有新版本 \(availableUpdateVersion)")
        }
        statusItem?.button?.toolTip = parts.joined(separator: " · ")
    }

    @objc private func openLauncher() { onOpenLauncher?() }
    @objc private func openGuide() { onOpenGuide?() }
    @objc private func openSync() { onOpenSync?() }
    @objc private func quit() { onQuit?() }
}
