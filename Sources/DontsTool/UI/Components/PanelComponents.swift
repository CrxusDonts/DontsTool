import AppKit
import DontsToolCore
import SwiftUI

struct LauncherPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? 0.988 : 1)
            .animation(Motion.hoverEasing, value: configuration.isPressed)
    }
}

/// 键盘键帽：↑↓、↵、esc 等。
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.keycapFont)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: Metrics.keycapCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.keycapCornerRadius)
                    .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
            )
    }
}

/// 结果行右侧的动作胶囊：选中或悬停时出现。
struct ActionCapsule: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text("↵").font(.system(size: 10, weight: .semibold))
        }
        .font(Theme.capsuleFont)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: Metrics.capsuleCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.capsuleCornerRadius)
                .strokeBorder(Theme.accentBorder, lineWidth: 0.5)
        )
    }
}

/// 关键词工具的快捷键标签：json、tr 等。
struct ShortcutTag: View {
    let keyword: String

    var body: some View {
        Text(keyword)
            .font(Theme.keycapFont)
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: Metrics.keycapCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.keycapCornerRadius)
                    .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
            )
    }
}

/// 26pt 紧凑图标块：应用/文件用系统图标，符号与字形用微玻璃着色块。
struct IconTile: View {
    let icon: ItemIcon

    var body: some View {
        Group {
            switch icon {
            case .application(let path), .file(let path):
                Image(nsImage: FileIconImage.image(for: path))
                    .resizable()
                    .scaledToFit()
                    .padding(1)
            case .symbol(let name, let tint):
                Image(systemName: name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(tint.style.foreground)
            case .glyph(let text, let tint):
                Text(text)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint.style.foreground)
            }
        }
        .frame(width: Metrics.iconSize, height: Metrics.iconSize)
        .background(tileBackground, in: RoundedRectangle(cornerRadius: Metrics.iconCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.iconCornerRadius)
                .strokeBorder(tileBorder, lineWidth: 0.5)
        )
    }

    private var tileBackground: Color {
        switch icon {
        case .symbol(_, let tint), .glyph(_, let tint):
            tint.style.background
        case .application, .file:
            Color.clear
        }
    }

    private var tileBorder: Color {
        switch icon {
        case .symbol(_, let tint), .glyph(_, let tint):
            tint.style.border
        default:
            Color.clear
        }
    }
}

/// 分组标题：常用 / 应用 / 工具 / 文件 / 网页。
struct GroupHeader: View {
    let group: ResultGroup
    let isDefaultList: Bool

    var body: some View {
        Text(title)
            .font(Theme.groupCaptionFont)
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.captionHorizontalInset)
            .padding(.vertical, Metrics.captionVerticalInset)
    }

    private var title: String {
        switch group {
        case .app:
            isDefaultList ? "常用" : "应用"
        case .tool:
            "工具"
        case .knowledge:
            "知识库"
        case .file:
            "文件"
        case .web:
            "网页"
        case .shortcut:
            "网址快捷入口"
        }
    }
}

/// 极简 32pt 玻璃底栏：品牌标识 + 实时状态 + 键位说明。
struct PanelFooterView: View {
    let statusText: String?
    let isWarning: Bool
    let isActionPanelOpen: Bool
    var onShowActions: (() -> Void)? = nil
    var hasActions = true

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
            Text("DontsTool")
                .font(Theme.footerFont.weight(.medium))
                .foregroundStyle(Theme.secondary)
            if let statusText {
                Text("·")
                    .foregroundStyle(Theme.tertiary)
                Text(statusText)
                    .font(Theme.footerFont)
                    .foregroundStyle(isWarning ? Theme.warning : Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isActionPanelOpen {
                legend(keys: ["↑↓"], label: "选择")
                dot
                legend(keys: ["↵"], label: "执行")
                dot
                legend(keys: ["esc"], label: "返回")
            } else {
                legend(keys: ["↑↓"], label: "选择")
                dot
                legend(keys: ["↵"], label: "执行")
                dot
                Button { onShowActions?() } label: {
                    legend(keys: ["⌘K"], label: "操作")
                }
                .buttonStyle(.plain)
                .disabled(!hasActions)
                .help("查看当前结果的所有操作（⌘K）")
                .accessibilityLabel("查看所有操作")
                dot
                legend(keys: ["esc"], label: "关闭")
            }
        }
        .padding(.horizontal, Metrics.panelHorizontalInset)
        .frame(height: Metrics.footerHeight)
        .background(Theme.footerBase)
        .overlay(alignment: .top) { Theme.separator.frame(height: 0.5) }
    }

    private var dot: some View {
        Text("·")
            .font(Theme.footerFont)
            .foregroundStyle(Theme.tertiary.opacity(0.6))
    }

    private func legend(keys: [String], label: String) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { KeyCap(text: $0) }
            }
            Text(label)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// ⌘K 动作面板：Liquid Glass 悬浮菜单。
struct ActionPaletteView: View {
    let itemTitle: String
    let actions: [ItemAction]
    let selectedIndex: Int
    let onExecute: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text("操作")
                    .font(Theme.sectionCaptionFont)
                    .foregroundStyle(Theme.tertiary)
                if !itemTitle.isEmpty {
                    Text(itemTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)

            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                ActionPaletteRow(
                    action: action,
                    isSelected: index == selectedIndex,
                    onExecute: { onExecute(index) }
                )
            }
        }
        .padding(5)
        .frame(width: 244, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.popoverBase)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("操作")
    }
}

private struct ActionPaletteRow: View {
    let action: ItemAction
    let isSelected: Bool
    let onExecute: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onExecute) {
            HStack(spacing: 8) {
                Image(systemName: action.symbol ?? "circle")
                    .font(.system(size: 12.5))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Theme.onSelectionAccent : Theme.secondary)
                Text(action.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Theme.onSelectionAccent : Theme.ink)
                Spacer(minLength: 8)
                if isSelected {
                    Text("↵")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.onSelectionAccent.opacity(0.85))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(LauncherPressStyle())
        .onHover { isHovered = $0 }
        .animation(Motion.hoverEasing, value: isHovered)
        .animation(Motion.paletteEasing, value: isSelected)
        .accessibilityLabel(action.title)
    }

    private var rowBackground: Color {
        if isSelected { return Theme.accent }
        if isHovered { return Theme.rowHover }
        return .clear
    }
}

/// 复制/执行反馈 Toast：悬浮毛玻璃胶囊。
struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.success)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Metrics.toastCornerRadius)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: Metrics.toastCornerRadius)
                .fill(Theme.toastBackground)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.toastCornerRadius)
                .strokeBorder(Theme.toastBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// 翻译/搜索进行中的转圈指示。
struct ProgressSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(Theme.accent)
    }
}
