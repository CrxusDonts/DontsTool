import AppKit
import SwiftUI

/// Workspace surfaces are intentionally separate from the compact launcher palette.
enum ToolTheme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Theme.hexColor(dark) : Theme.hexColor(light) }
    }
    static let shellNS = adaptive(0xE7E5DF, 0x282D30)
    static let toolbarNS = adaptive(0xEAE8E2, 0x2B3034)
    static let workspaceNS = adaptive(0xEFEEE9, 0x24282B)
    static let editorNS = adaptive(0xF7F5F0, 0x1D2225)
    static let gutterNS = adaptive(0xEEEBE4, 0x20272B)
    static let inkNS = adaptive(0x252B2D, 0xE8ECEB)
    static let secondaryNS = adaptive(0x66716E, 0x9DAAA7)
    static let borderNS = adaptive(0xD1D1C9, 0x3B4548)
    static let accentNS = adaptive(0x18786F, 0x6CD4BD)
    static let stringNS = adaptive(0xA65B3E, 0xE4B28B)
    static let numberNS = adaptive(0x765CAD, 0xB6A4DF)
    static let keyNS = adaptive(0x18786F, 0x8BCDBB)
    static let modifiedNS = adaptive(0xF5EACD, 0x403A2C)
    static let shell = Color(nsColor: shellNS)
    static let toolbar = Color(nsColor: toolbarNS)
    static let workspace = Color(nsColor: workspaceNS)
    static let editor = Color(nsColor: editorNS)
    static let ink = Color(nsColor: inkNS)
    static let secondary = Color(nsColor: secondaryNS)
    static let border = Color(nsColor: borderNS)
    static let accent = Color(nsColor: accentNS)
    static let onAccent = Color(nsColor: adaptive(0xFFFFFF, 0x183A33))
    static let selection = Color(nsColor: adaptive(0xDCEAE3, 0x3A514C))
}
