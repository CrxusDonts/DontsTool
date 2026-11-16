import AppKit
import DontsToolCore
import SwiftUI

/// Raycast × Linear × macOS 原生克制色板：纯中性灰与纸白表面，极少装饰色。
/// 所有界面颜色必须从这里取，禁止在视图里写死色值。
enum Theme {
    /// 6 位 RGB，不透明。
    static func hexColor(_ rgb: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    static func rgba(_ rgb: UInt32, _ alpha: UInt32) -> NSColor {
        hexColor(rgb).withAlphaComponent(CGFloat(alpha) / 255)
    }

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: 表面（纯中性灰 / 纸白）

    static let panelSolid = dynamic(hexColor(0xFAFAFB), hexColor(0x1C1C1E))
    static let panelBase = dynamic(rgba(0xFAFAFB, 0xEC), rgba(0x1C1C1E, 0xEC))
    static let headerBase = dynamic(rgba(0xFFFFFF, 0x45), rgba(0xFFFFFF, 0x03))
    static let footerBase = dynamic(rgba(0xF4F4F5, 0x85), rgba(0x18181A, 0x88))
    static let popoverBase = dynamic(rgba(0xFFFFFF, 0xF6), rgba(0x242426, 0xF6))
    static let glassCardFill = dynamic(rgba(0xFFFFFF, 0x90), rgba(0x242426, 0x88))
    static let glassCardBorder = dynamic(rgba(0x000000, 0x0E), rgba(0xFFFFFF, 0x10))
    static let rowHover = dynamic(rgba(0x000000, 0x08), rgba(0xFFFFFF, 0x0A))
    static let selection = dynamic(rgba(0x000000, 0x10), rgba(0xFFFFFF, 0x16))
    static let selectionBorder = dynamic(rgba(0x000000, 0x08), rgba(0xFFFFFF, 0x0C))
    static let separator = dynamic(rgba(0x000000, 0x0E), rgba(0xFFFFFF, 0x10))
    static let panelBorder = dynamic(rgba(0x000000, 0x14), rgba(0xFFFFFF, 0x16))
    static let panelHighlight = dynamic(rgba(0xFFFFFF, 0xCC), rgba(0xFFFFFF, 0x1A))

    // MARK: 文本

    static let ink = dynamic(hexColor(0x111113), hexColor(0xF4F4F5))
    static let secondary = dynamic(hexColor(0x6E6E73), hexColor(0xA1A1AA))
    static let tertiary = dynamic(hexColor(0x8E8E93), hexColor(0x71717A))
    static let onAccent = dynamic(hexColor(0xFFFFFF), hexColor(0xFFFFFF))

    /// AppKit 控件（搜索框等）使用的同名动态色。
    static let inkNS = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexColor(0xF4F4F5) : hexColor(0x111113) }
    static let secondaryNS = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexColor(0xA1A1AA) : hexColor(0x6E6E73) }
    static let tertiaryNS = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexColor(0x71717A) : hexColor(0x8E8E93) }

    // MARK: 语义（仅用于主动作与状态）

    static let accent = dynamic(hexColor(0x007AFF), hexColor(0x0A84FF))
    static let accentFill = dynamic(rgba(0x007AFF, 0x14), rgba(0x0A84FF, 0x1E))
    static let accentBorder = dynamic(rgba(0x007AFF, 0x28), rgba(0x0A84FF, 0x36))
    static let onSelectionAccent = dynamic(hexColor(0xFFFFFF), hexColor(0xFFFFFF))
    static let success = dynamic(hexColor(0x15803D), hexColor(0x4ADE80))
    static let warning = dynamic(hexColor(0xB45309), hexColor(0xFBBF24))

    // MARK: 控件

    static let controlFill = dynamic(rgba(0x000000, 0x08), rgba(0xFFFFFF, 0x0E))
    static let controlBorder = dynamic(rgba(0x000000, 0x12), rgba(0xFFFFFF, 0x16))
    static let toastBackground = dynamic(rgba(0xFFFFFF, 0xF5), rgba(0x242426, 0xF5))
    static let toastBorder = dynamic(rgba(0x000000, 0x14), rgba(0xFFFFFF, 0x18))

    // MARK: 字体

    static let searchFont = Font.system(size: 17, weight: .regular)
    static let rowTitleFont = Font.system(size: 13, weight: .medium)
    static let rowSubtitleFont = Font.system(size: 11.5, weight: .regular)
    static let groupCaptionFont = Font.system(size: 11, weight: .medium)
    static let footerFont = Font.system(size: 11, weight: .regular)
    static let keycapFont = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    static let capsuleFont = Font.system(size: 11, weight: .medium)
    static let settingsTitleFont = Font.system(size: 18, weight: .semibold)
    static let sectionCaptionFont = Font.system(size: 11, weight: .medium)
    static let settingTitleFont = Font.system(size: 13, weight: .medium)
    static let settingSubtitleFont = Font.system(size: 11.5, weight: .regular)
}

struct IconTintStyle {
    let background: Color
    let foreground: Color
    let border: Color
}

extension IconTint {
    /// 低饱和语义着色：主要用于环境徽章（prod / test 等），保持克制耐看。
    var style: IconTintStyle {
        func make(
            lightBG: UInt32, lightAlpha: UInt32, lightFG: UInt32,
            darkBG: UInt32, darkAlpha: UInt32, darkFG: UInt32
        ) -> IconTintStyle {
            IconTintStyle(
                background: Theme.dynamic(
                    Theme.rgba(lightBG, lightAlpha),
                    Theme.rgba(darkBG, darkAlpha)
                ),
                foreground: Theme.dynamic(
                    Theme.hexColor(lightFG),
                    Theme.hexColor(darkFG)
                ),
                border: Theme.dynamic(
                    Theme.rgba(lightFG, 0x24),
                    Theme.rgba(darkFG, 0x2A)
                )
            )
        }
        switch self {
        case .blue:
            return make(lightBG: 0x007AFF, lightAlpha: 0x12, lightFG: 0x0062CC,
                        darkBG: 0x0A84FF, darkAlpha: 0x1E, darkFG: 0x60A5FA)
        case .sky:
            return make(lightBG: 0x0284C7, lightAlpha: 0x12, lightFG: 0x0369A1,
                        darkBG: 0x38BDF8, darkAlpha: 0x1E, darkFG: 0x7DD3FC)
        case .teal:
            return make(lightBG: 0x0F766E, lightAlpha: 0x12, lightFG: 0x0F766E,
                        darkBG: 0x2DD4BF, darkAlpha: 0x1E, darkFG: 0x5EEAD4)
        case .green:
            return make(lightBG: 0x15803D, lightAlpha: 0x12, lightFG: 0x15803D,
                        darkBG: 0x4ADE80, darkAlpha: 0x1E, darkFG: 0x86EFAC)
        case .amber:
            return make(lightBG: 0xB45309, lightAlpha: 0x14, lightFG: 0xB45309,
                        darkBG: 0xFBBF24, darkAlpha: 0x1E, darkFG: 0xFCD34D)
        case .orange:
            return make(lightBG: 0xC2410C, lightAlpha: 0x12, lightFG: 0xC2410C,
                        darkBG: 0xFB923C, darkAlpha: 0x1E, darkFG: 0xFDBA74)
        case .red:
            return make(lightBG: 0xDC2626, lightAlpha: 0x12, lightFG: 0xDC2626,
                        darkBG: 0xF87171, darkAlpha: 0x1E, darkFG: 0xFCA5A5)
        case .purple:
            return make(lightBG: 0x7E22CE, lightAlpha: 0x12, lightFG: 0x7E22CE,
                        darkBG: 0xC084FC, darkAlpha: 0x1E, darkFG: 0xD8B4FE)
        case .indigo:
            return make(lightBG: 0x4338CA, lightAlpha: 0x12, lightFG: 0x4338CA,
                        darkBG: 0x818CF8, darkAlpha: 0x1E, darkFG: 0xA5B4FC)
        case .gray:
            return make(lightBG: 0x000000, lightAlpha: 0x08, lightFG: 0x52525B,
                        darkBG: 0xFFFFFF, darkAlpha: 0x12, darkFG: 0xA1A1AA)
        }
    }
}
