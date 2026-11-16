import AppKit
import DontsToolCore
import SwiftUI

/// macOS 26 Liquid Glass 设计令牌：自适应浅色冰白玻璃与深色黑曜石玻璃。
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

    // MARK: 表面（Liquid Glass）

    static let panelSolid = dynamic(hexColor(0xF8FAFC), hexColor(0x161922))
    static let panelBase = dynamic(rgba(0xFFFFFF, 0xCC), rgba(0x161922, 0xCE))
    static let headerBase = dynamic(rgba(0xFFFFFF, 0x58), rgba(0xFFFFFF, 0x05))
    static let footerBase = dynamic(rgba(0xF1F5F9, 0x7A), rgba(0x0B0D12, 0x72))
    static let popoverBase = dynamic(rgba(0xFFFFFF, 0xE6), rgba(0x1B1F2A, 0xE8))
    static let glassCardFill = dynamic(rgba(0xFFFFFF, 0x70), rgba(0xFFFFFF, 0x06))
    static let glassCardBorder = dynamic(rgba(0x0F172A, 0x10), rgba(0xFFFFFF, 0x16))
    static let rowHover = dynamic(rgba(0x0F172A, 0x08), rgba(0xFFFFFF, 0x0B))
    static let selection = dynamic(rgba(0x0A84FF, 0x13), rgba(0x38BDF8, 0x1A))
    static let selectionBorder = dynamic(rgba(0x0A84FF, 0x36), rgba(0x38BDF8, 0x3A))
    static let separator = dynamic(rgba(0x0F172A, 0x12), rgba(0xFFFFFF, 0x18))
    static let panelBorder = dynamic(rgba(0x0F172A, 0x14), rgba(0xFFFFFF, 0x1E))
    static let panelHighlight = dynamic(rgba(0xFFFFFF, 0xEC), rgba(0xFFFFFF, 0x24))

    // MARK: 文本

    static let ink = dynamic(hexColor(0x0F172A), hexColor(0xF1F5F9))
    static let secondary = dynamic(hexColor(0x475569), hexColor(0x94A3B8))
    static let tertiary = dynamic(hexColor(0x64748B), hexColor(0x64748B))
    static let onAccent = dynamic(hexColor(0xFFFFFF), hexColor(0xFFFFFF))

    /// AppKit 控件（搜索框等）使用的同名动态色。
    static let inkNS = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexColor(0xF1F5F9) : hexColor(0x0F172A) }
    static let secondaryNS = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexColor(0x94A3B8) : hexColor(0x475569) }
    static let tertiaryNS = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexColor(0x64748B) : hexColor(0x64748B) }

    // MARK: 语义

    static let accent = dynamic(hexColor(0x0A84FF), hexColor(0x38BDF8))
    static let accentFill = dynamic(rgba(0x0A84FF, 0x16), rgba(0x38BDF8, 0x1F))
    static let accentBorder = dynamic(rgba(0x0A84FF, 0x38), rgba(0x38BDF8, 0x42))
    static let onSelectionAccent = dynamic(hexColor(0xFFFFFF), hexColor(0x082032))
    static let success = dynamic(hexColor(0x059669), hexColor(0x34D399))
    static let warning = dynamic(hexColor(0xD97706), hexColor(0xFBBF24))

    // MARK: 控件

    static let controlFill = dynamic(rgba(0x0F172A, 0x0A), rgba(0xFFFFFF, 0x12))
    static let controlBorder = dynamic(rgba(0x0F172A, 0x18), rgba(0xFFFFFF, 0x22))
    static let toastBackground = dynamic(rgba(0xFFFFFF, 0xF2), rgba(0x1E2330, 0xF2))
    static let toastBorder = dynamic(rgba(0x0F172A, 0x16), rgba(0xFFFFFF, 0x22))

    // MARK: 字体

    static let searchFont = Font.system(size: 18, weight: .regular)
    static let rowTitleFont = Font.system(size: 13.5, weight: .medium)
    static let rowSubtitleFont = Font.system(size: 11, weight: .regular)
    static let groupCaptionFont = Font.system(size: 10.5, weight: .semibold)
    static let footerFont = Font.system(size: 11, weight: .regular)
    static let keycapFont = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    static let capsuleFont = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let settingsTitleFont = Font.system(size: 19, weight: .semibold)
    static let sectionCaptionFont = Font.system(size: 10.5, weight: .semibold)
    static let settingTitleFont = Font.system(size: 13, weight: .medium)
    static let settingSubtitleFont = Font.system(size: 11.5, weight: .regular)
}

struct IconTintStyle {
    let background: Color
    let foreground: Color
    let border: Color
}

extension IconTint {
    /// 图标块着色：现代高饱和微玻璃质感。
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
                    Theme.rgba(lightFG, 0x36),
                    Theme.rgba(darkFG, 0x38)
                )
            )
        }
        switch self {
        case .blue:
            return make(lightBG: 0x0A84FF, lightAlpha: 0x18, lightFG: 0x0066CC,
                        darkBG: 0x3B82F6, darkAlpha: 0x26, darkFG: 0x60A5FA)
        case .sky:
            return make(lightBG: 0x0EA5E9, lightAlpha: 0x18, lightFG: 0x0369A1,
                        darkBG: 0x38BDF8, darkAlpha: 0x26, darkFG: 0x7DD3FC)
        case .teal:
            return make(lightBG: 0x14B8A6, lightAlpha: 0x18, lightFG: 0x0F766E,
                        darkBG: 0x2DD4BF, darkAlpha: 0x26, darkFG: 0x5EEAD4)
        case .green:
            return make(lightBG: 0x10B981, lightAlpha: 0x18, lightFG: 0x047857,
                        darkBG: 0x34D399, darkAlpha: 0x26, darkFG: 0x6EE7B7)
        case .amber:
            return make(lightBG: 0xF59E0B, lightAlpha: 0x1E, lightFG: 0xB45309,
                        darkBG: 0xFBBF24, darkAlpha: 0x26, darkFG: 0xFCD34D)
        case .orange:
            return make(lightBG: 0xF97316, lightAlpha: 0x18, lightFG: 0xC2410C,
                        darkBG: 0xFB923C, darkAlpha: 0x26, darkFG: 0xFDBA74)
        case .red:
            return make(lightBG: 0xEF4444, lightAlpha: 0x18, lightFG: 0xDC2626,
                        darkBG: 0xF87171, darkAlpha: 0x26, darkFG: 0xFCA5A5)
        case .purple:
            return make(lightBG: 0xA855F7, lightAlpha: 0x18, lightFG: 0x7E22CE,
                        darkBG: 0xC084FC, darkAlpha: 0x26, darkFG: 0xD8B4FE)
        case .indigo:
            return make(lightBG: 0x6366F1, lightAlpha: 0x18, lightFG: 0x4338CA,
                        darkBG: 0x818CF8, darkAlpha: 0x26, darkFG: 0xA5B4FC)
        case .gray:
            return make(lightBG: 0x0F172A, lightAlpha: 0x0C, lightFG: 0x475569,
                        darkBG: 0xFFFFFF, darkAlpha: 0x16, darkFG: 0xCBD5E1)
        }
    }
}
