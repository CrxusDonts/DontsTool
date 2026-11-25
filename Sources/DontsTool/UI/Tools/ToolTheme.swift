import AppKit
import SwiftUI

/// 独立工具窗口与编辑器配色：纯中性白/炭灰，克制的 Raycast × Linear × Zed 语义层次。
enum ToolTheme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Theme.hexColor(dark) : Theme.hexColor(light) }
    }

    static func dynamicNS(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    // MARK: 表面（AppKit）

    static let shellNS = adaptive(0xF5F5F7, 0x1A1A1D)
    static let toolbarNS = adaptive(0xF8F8FA, 0x1E1E21)
    static let workspaceNS = adaptive(0xEFEFF2, 0x141416)
    static let editorNS = adaptive(0xFFFFFF, 0x161618)
    static let gutterNS = adaptive(0xF7F7F9, 0x19191C)
    static let inkNS = adaptive(0x111113, 0xF4F4F5)
    static let secondaryNS = adaptive(0x6E6E73, 0xA1A1AA)
    static let borderNS = adaptive(0xE2E2E6, 0x2A2A2E)
    static let accentNS = adaptive(0x007AFF, 0x0A84FF)

    // MARK: 6 色 JSON 语法高亮

    static let keyNS = adaptive(0x0369A1, 0x7DD3FC)
    static let stringNS = adaptive(0x15803D, 0x6EE7B7)
    static let numberNS = adaptive(0xB45309, 0xFCD34D)
    static let booleanNS = adaptive(0x7C3AED, 0xC4B5FD)
    static let nullNS = adaptive(0xBE123C, 0xFDA4AF)
    static let punctuationNS = adaptive(0x64748B, 0x8E8E93)
    static let modifiedNS = adaptive(0xFEF3C7, 0x3B3018)

    // MARK: 编辑器辅助线、折叠胶囊与 Diff 行高亮

    static let activeLineNS = dynamicNS(Theme.rgba(0x007AFF, 0x0A), Theme.rgba(0xFFFFFF, 0x0A))
    static let indentGuideNS = dynamicNS(Theme.rgba(0x000000, 0x0D), Theme.rgba(0xFFFFFF, 0x0D))
    static let foldHoverFillNS = dynamicNS(Theme.rgba(0x000000, 0x0E), Theme.rgba(0xFFFFFF, 0x14))
    static let foldCollapsedFillNS = dynamicNS(Theme.rgba(0x007AFF, 0x1A), Theme.rgba(0x0A84FF, 0x28))
    static let foldCollapsedBorderNS = dynamicNS(Theme.rgba(0x007AFF, 0x3A), Theme.rgba(0x38BDF8, 0x45))
    static let foldCollapsedTextNS = adaptive(0x0062CC, 0x93C5FD)

    static let diffAddedLineNS = dynamicNS(Theme.rgba(0x15803D, 0x12), Theme.rgba(0x4ADE80, 0x14))
    static let diffAddedBarNS = adaptive(0x15803D, 0x4ADE80)
    static let diffRemovedLineNS = dynamicNS(Theme.rgba(0xDC2626, 0x12), Theme.rgba(0xF87171, 0x14))
    static let diffRemovedBarNS = adaptive(0xDC2626, 0xF87171)
    static let diffModifiedLineNS = dynamicNS(Theme.rgba(0xB45309, 0x14), Theme.rgba(0xFBBF24, 0x15))
    static let diffModifiedBarNS = adaptive(0xB45309, 0xFBBF24)

    // MARK: SwiftUI 表面与语义令牌

    static let shell = Color(nsColor: shellNS)
    static let toolbar = Color(nsColor: toolbarNS)
    static let workspace = Color(nsColor: workspaceNS)
    static let editor = Color(nsColor: editorNS)
    static let gutter = Color(nsColor: gutterNS)
    static let ink = Color(nsColor: inkNS)
    static let secondary = Color(nsColor: secondaryNS)
    static let border = Color(nsColor: borderNS)
    static let accent = Color(nsColor: accentNS)
    static let onAccent = Color(nsColor: adaptive(0xFFFFFF, 0xFFFFFF))
    static let selection = Theme.selection

    static let syntaxKey = Color(nsColor: keyNS)
    static let syntaxString = Color(nsColor: stringNS)
    static let syntaxNumber = Color(nsColor: numberNS)
    static let syntaxBoolean = Color(nsColor: booleanNS)
    static let syntaxNull = Color(nsColor: nullNS)
    static let syntaxPunctuation = Color(nsColor: punctuationNS)

    static let foldHoverFill = Color(nsColor: foldHoverFillNS)
    static let foldCollapsedFill = Color(nsColor: foldCollapsedFillNS)
    static let foldCollapsedBorder = Color(nsColor: foldCollapsedBorderNS)
    static let foldCollapsedText = Color(nsColor: foldCollapsedTextNS)

    static let diffAdded = Color(nsColor: diffAddedBarNS)
    static let diffRemoved = Color(nsColor: diffRemovedBarNS)
    static let diffModified = Color(nsColor: diffModifiedBarNS)
}
