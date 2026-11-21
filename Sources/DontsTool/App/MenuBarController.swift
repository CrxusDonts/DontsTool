import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    weak var updates: AppUpdateController? {
        didSet { bindUpdates() }
    }
    var onOpenLauncher: (() -> Void)?
    var onOpenGuide: (() -> Void)?
    var onQuit: (() -> Void)?
    var hotKeyDisplay = "⌥Space" {
        didSet { refreshToolTip() }
    }

    private var statusItem: NSStatusItem?
    private var updateMenuItem: NSMenuItem?
    private var availableUpdateVersion: String?
    private var updateCancellable: AnyCancellable?

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
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 DontsTool", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        bindUpdates()
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

    private func refreshToolTip() {
        let base = "DontsTool（\(hotKeyDisplay)）"
        statusItem?.button?.toolTip = availableUpdateVersion.map { "\(base) · 有新版本 \($0)" } ?? base
    }

    @objc private func openLauncher() { onOpenLauncher?() }
    @objc private func openGuide() { onOpenGuide?() }
    @objc private func quit() { onQuit?() }
}
