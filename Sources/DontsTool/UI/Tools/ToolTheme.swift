import AppKit
import SwiftUI

/// 独立工具窗口与划词浮卡的配色令牌：与 Liquid Glass 系统对齐。
enum ToolTheme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Theme.hexColor(dark) : Theme.hexColor(light) }
    }

    static let shellNS = adaptive(0xF1F5F9, 0x161922)
    static let toolbarNS = adaptive(0xF8FAFC, 0x1B1F2A)
    static let workspaceNS = adaptive(0xF1F5F9, 0x12151C)
    static let editorNS = adaptive(0xFFFFFF, 0x0F1218)
    static let gutterNS = adaptive(0xF8FAFC, 0x13171F)
    static let inkNS = adaptive(0x0F172A, 0xF1F5F9)
    static let secondaryNS = adaptive(0x475569, 0x94A3B8)
    static let borderNS = adaptive(0xE2E8F0, 0x262C3A)
    static let accentNS = adaptive(0x0A84FF, 0x38BDF8)
    static let stringNS = adaptive(0x059669, 0x34D399)
    static let numberNS = adaptive(0xD97706, 0xFBBF24)
    static let keyNS = adaptive(0x0369A1, 0x7DD3FC)
    static let modifiedNS = adaptive(0xFEF3C7, 0x3B3018)

    static let shell = Color(nsColor: shellNS)
    static let toolbar = Color(nsColor: toolbarNS)
    static let workspace = Color(nsColor: workspaceNS)
    static let editor = Color(nsColor: editorNS)
    static let ink = Color(nsColor: inkNS)
    static let secondary = Color(nsColor: secondaryNS)
    static let border = Color(nsColor: borderNS)
    static let accent = Color(nsColor: accentNS)
    static let onAccent = Color(nsColor: adaptive(0xFFFFFF, 0x082032))
    static let selection = Theme.selection
}
