import AppKit
import SwiftUI

/// 独立工具窗口与编辑器配色：纯中性白/炭灰，克制的 Xcode/CotEditor 语法色。
enum ToolTheme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Theme.hexColor(dark) : Theme.hexColor(light) }
    }

    static let shellNS = adaptive(0xF7F7F8, 0x18181A)
    static let toolbarNS = adaptive(0xF7F7F8, 0x1C1C1E)
    static let workspaceNS = adaptive(0xF4F4F5, 0x141416)
    static let editorNS = adaptive(0xFFFFFF, 0x1C1C1E)
    static let gutterNS = adaptive(0xFAFAFB, 0x18181A)
    static let inkNS = adaptive(0x111113, 0xF4F4F5)
    static let secondaryNS = adaptive(0x6E6E73, 0xA1A1AA)
    static let borderNS = adaptive(0xE5E5E7, 0x2C2C2E)
    static let accentNS = adaptive(0x007AFF, 0x0A84FF)
    static let stringNS = adaptive(0x15803D, 0x73C991)
    static let numberNS = adaptive(0xB45309, 0xE2C08D)
    static let keyNS = adaptive(0x1E293B, 0x9CDCFE)
    static let modifiedNS = adaptive(0xFEF3C7, 0x3B3018)

    static let shell = Color(nsColor: shellNS)
    static let toolbar = Color(nsColor: toolbarNS)
    static let workspace = Color(nsColor: workspaceNS)
    static let editor = Color(nsColor: editorNS)
    static let ink = Color(nsColor: inkNS)
    static let secondary = Color(nsColor: secondaryNS)
    static let border = Color(nsColor: borderNS)
    static let accent = Color(nsColor: accentNS)
    static let onAccent = Color(nsColor: adaptive(0xFFFFFF, 0xFFFFFF))
    static let selection = Theme.selection
}
