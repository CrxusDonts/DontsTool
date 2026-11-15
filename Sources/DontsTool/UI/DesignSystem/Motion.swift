import AppKit
import SwiftUI

/// 每次读取都遵循当前系统的“减少动态效果”设置。
enum Motion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func duration(_ milliseconds: Double) -> Double {
        reduceMotion ? 0.001 : milliseconds / 1000
    }

    static var panelEnter: Double { duration(200) }
    static var panelExit: Double { duration(120) }
    static var rowHover: Double { duration(100) }
    static var selectionChange: Double { duration(140) }
    static var listUpdate: Double { duration(120) }
    static var toastIn: Double { duration(180) }
    static var toastOut: Double { duration(140) }
    static let toastHold = 1.4
    static var settingsSwitch: Double { duration(160) }
    static var spinnerPeriod: Double { duration(800) }

    static var enterEasing: Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: panelEnter)
    }
    static var exitEasing: Animation {
        .timingCurve(0.4, 0, 1, 1, duration: panelExit)
    }
    static var easeOut: Animation { .easeOut(duration: selectionChange) }
    static var listEasing: Animation { .easeOut(duration: listUpdate) }
    static var switchEasing: Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: settingsSwitch)
    }
    static var selectionGlide: Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration(160))
    }
    static var paletteEasing: Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration(140))
    }
    static var contentEasing: Animation { .easeOut(duration: listUpdate) }
    static var hoverEasing: Animation { .easeOut(duration: rowHover) }

    /// 与交互稿的 cubic-bezier(.2,.8,.2,1) 使用相同的时间曲线。
    static func panelProgress(_ progress: Double, dismissing: Bool) -> Double {
        let x = min(1, max(0, progress))
        if dismissing { return x * x }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<16 {
            let t = (lower + upper) / 2
            let inverse = 1 - t
            let curveX = 3 * inverse * inverse * t * 0.2 + 3 * inverse * t * t * 0.2 + t * t * t
            if curveX < x { lower = t } else { upper = t }
        }
        let t = (lower + upper) / 2
        let inverse = 1 - t
        return 3 * inverse * inverse * t * 0.8 + 3 * inverse * t * t + t * t * t
    }
}
