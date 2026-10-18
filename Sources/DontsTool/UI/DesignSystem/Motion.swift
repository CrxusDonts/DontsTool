import AppKit
import SwiftUI

/// 动效令牌：design/MOTION.md。系统开启“减少动态效果”时全部降级为 1ms。
enum Motion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func duration(_ milliseconds: Double) -> Double {
        reduceMotion ? 0.001 : milliseconds / 1000
    }

    static let panelEnter = duration(220)
    static let panelExit = duration(140)
    static let rowHover = duration(100)
    static let selectionChange = duration(140)
    static let listUpdate = duration(120)
    static let toastIn = duration(180)
    static let toastOut = duration(140)
    static let toastHold = 1.4
    static let settingsSwitch = duration(160)
    static let spinnerPeriod = duration(800)

    static let enterEasing = Animation.timingCurve(0.16, 1, 0.3, 1, duration: panelEnter)
    static let exitEasing = Animation.timingCurve(0.4, 0, 1, 1, duration: panelExit)
    static let easeOut = Animation.easeOut(duration: selectionChange)
    static let listEasing = Animation.easeOut(duration: listUpdate)
    static let switchEasing = Animation.timingCurve(0.22, 1, 0.36, 1, duration: settingsSwitch)
}
