import AppKit

@MainActor
final class MenuBarController: NSObject {
    var onOpenLauncher: (() -> Void)?
    var onQuit: (() -> Void)?
    var hotKeyDisplay = "⌥Space" {
        didSet { statusItem?.button?.toolTip = "DontsTool（\(hotKeyDisplay)）" }
    }

    private var statusItem: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "d.square", accessibilityDescription: "DontsTool")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "DontsTool（\(hotKeyDisplay)）"
        item.button?.setAccessibilityLabel("DontsTool")
        item.autosaveName = "DontsToolStatusItem"

        let menu = NSMenu()
        let open = NSMenuItem(title: "打开启动器", action: #selector(openLauncher), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 DontsTool", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func openLauncher() { onOpenLauncher?() }
    @objc private func quit() { onQuit?() }
}
