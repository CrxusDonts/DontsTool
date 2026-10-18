import AppKit
import DontsToolCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var checkingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Performance.mark("cold.start", since: AppBoot.start)
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        installApplicationMenu()
        let controller = AppController()
        self.controller = controller
        controller.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller?.hasKnowledgeWindows == true else { return .terminateNow }
        guard !checkingTermination else { return .terminateLater }
        checkingTermination = true
        Task { [weak self] in
            guard let self else { return }
            let approved = await controller?.prepareToTerminate() ?? true
            checkingTermination = false
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
