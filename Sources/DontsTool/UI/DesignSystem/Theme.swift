import AppKit
import DontsToolCore
import SwiftUI

/// 设计令牌：design/DESIGN.md 的浅色映射与深色石墨配色。
/// 所有界面颜色必须从这里取，禁止在视图里写死色值。
///
/// 注意：透明度一律通过 `rgba` 显式传入，不能把 `0xRRGGBBAA` 直接塞进
/// UInt32——`0x00000008` 这类前导零值会被误判成不透明深色。
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
        let base = hexColor(rgb)
        return base.withAlphaComponent(CGFloat(alpha) / 255)
    }

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: 表面

    static let panelSolid = dynamic(hexColor(0xEEECE6), hexColor(0x252C2F))
    static let panelBase = dynamic(rgba(0xEEECE6, 0xED), rgba(0x252C2F, 0xEE))
    static let headerBase = dynamic(rgba(0xF7F5EF, 0x80), rgba(0x30393B, 0x70))
    static let footerBase = dynamic(rgba(0xE4E4DC, 0x80), rgba(0x1D2527, 0x88))
    static let rowHover = dynamic(rgba(0x24272D, 0x06), rgba(0xFFFFFF, 0x0A))
    static let selection = dynamic(hexColor(0xDCEAE3), rgba(0x6CD4BD, 0x20))
    static let selectionBorder = dynamic(hexColor(0xB2CEC2), rgba(0x6CD4BD, 0x48))
    static let separator = dynamic(rgba(0x000000, 0x0D), rgba(0xFFFFFF, 0x1A))
    static let panelBorder = dynamic(rgba(0x000000, 0x14), rgba(0xFFFFFF, 0x1A))

    // MARK: 文本

    static let ink = dynamic(hexColor(0x252E2B), hexColor(0xE8EFEB))
    static let secondary = dynamic(hexColor(0x5B6962), hexColor(0xACBDB5))
    static let tertiary = dynamic(hexColor(0x626F69), hexColor(0x95A79F))
    static let onAccent = dynamic(hexColor(0xFFFFFF), hexColor(0xFFFFFF))

    /// AppKit 控件（搜索框等）使用的同名动态色。
    static let inkNS = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexColor(0xE8EFEB) : hexColor(0x252E2B) }
    static let secondaryNS = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexColor(0xACBDB5) : hexColor(0x5B6962) }
    static let tertiaryNS = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hexColor(0x95A79F) : hexColor(0x626F69) }

    // MARK: 语义

    static let accent = dynamic(hexColor(0x18786F), hexColor(0x6CD4BD))
    static let accentFill = dynamic(rgba(0x18786F, 0x14), rgba(0x6CD4BD, 0x22))
    static let accentBorder = dynamic(rgba(0x18786F, 0x32), rgba(0x6CD4BD, 0x48))
    static let onSelectionAccent = dynamic(hexColor(0xFFFFFF), hexColor(0x173C33))
    static let success = dynamic(hexColor(0x27845F), hexColor(0x79C7A5))
    static let warning = dynamic(hexColor(0xB45309), hexColor(0xE7B46E))

    // MARK: 控件

    static let controlFill = dynamic(rgba(0x000000, 0x08), rgba(0xFFFFFF, 0x14))
    static let controlBorder = dynamic(rgba(0x000000, 0x1A), rgba(0xFFFFFF, 0x26))
    static let toastBackground = dynamic(rgba(0xFFFFFF, 0xF5), rgba(0x2E3034, 0xF5))
    static let toastBorder = dynamic(hexColor(0xDCE1E8), rgba(0xFFFFFF, 0x26))

    // MARK: 字体（design/DESIGN.md 第 3 节）

    static let searchFont = Font.system(size: 20, weight: .regular)
    static let rowTitleFont = Font.system(size: 14, weight: .medium)
    static let rowSubtitleFont = Font.system(size: 11, weight: .regular)
    static let groupCaptionFont = Font.system(size: 11, weight: .medium)
    static let footerFont = Font.system(size: 11, weight: .regular)
    static let keycapFont = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let capsuleFont = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let settingsTitleFont = Font.system(size: 20, weight: .bold)
    static let sectionCaptionFont = Font.system(size: 11, weight: .semibold)
    static let settingTitleFont = Font.system(size: 13, weight: .medium)
    static let settingSubtitleFont = Font.system(size: 12, weight: .regular)
}

struct IconTintStyle {
    let background: Color
    let foreground: Color
    let border: Color
}

extension IconTint {
    /// 图标块着色：浅色低饱和底 + 深色前景，深色模式提亮。
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
                    Theme.rgba(lightFG, 0x40),
                    Theme.rgba(darkFG, 0x40)
                )
            )
        }
        switch self {
        case .blue:
            return make(lightBG: 0x3478F6, lightAlpha: 0x14, lightFG: 0x3478F6,
                        darkBG: 0x458BFF, darkAlpha: 0x24, darkFG: 0x7FB3FF)
        case .sky:
            return make(lightBG: 0x0EA5E9, lightAlpha: 0x14, lightFG: 0x0284C7,
                        darkBG: 0x38BDF8, darkAlpha: 0x24, darkFG: 0x7DD3FC)
        case .teal:
            return make(lightBG: 0x14B8A6, lightAlpha: 0x14, lightFG: 0x0F766E,
                        darkBG: 0x2DD4BF, darkAlpha: 0x24, darkFG: 0x5EEAD4)
        case .green:
            return make(lightBG: 0x22C55E, lightAlpha: 0x14, lightFG: 0x15803D,
                        darkBG: 0x4ADE80, darkAlpha: 0x24, darkFG: 0x86EFAC)
        case .amber:
            return make(lightBG: 0xF59E0B, lightAlpha: 0x1A, lightFG: 0xB45309,
                        darkBG: 0xFBBF24, darkAlpha: 0x24, darkFG: 0xFCD34D)
        case .orange:
            return make(lightBG: 0xF97316, lightAlpha: 0x14, lightFG: 0xC2410C,
                        darkBG: 0xFB923C, darkAlpha: 0x24, darkFG: 0xFDBA74)
        case .red:
            return make(lightBG: 0xEF4444, lightAlpha: 0x14, lightFG: 0xDC2626,
                        darkBG: 0xF87171, darkAlpha: 0x24, darkFG: 0xFCA5A5)
        case .purple:
            return make(lightBG: 0xA855F7, lightAlpha: 0x14, lightFG: 0x9333EA,
                        darkBG: 0xC084FC, darkAlpha: 0x24, darkFG: 0xD8B4FE)
        case .indigo:
            return make(lightBG: 0x6366F1, lightAlpha: 0x14, lightFG: 0x4F46E5,
                        darkBG: 0x818CF8, darkAlpha: 0x24, darkFG: 0xA5B4FC)
        case .gray:
            return make(lightBG: 0x000000, lightAlpha: 0x08, lightFG: 0x55595F,
                        darkBG: 0xFFFFFF, darkAlpha: 0x14, darkFG: 0xC7CAD0)
        }
    }
}
