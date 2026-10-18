import AppKit
import Foundation

/// 进程启动时刻，用于冷启动耗时埋点。在 main() 首行赋值。
enum AppBoot {
    nonisolated(unsafe) static var start = ContinuousClock.Instant.now
}

@main
enum DontsToolMain {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        AppBoot.start = .now
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
