import AppKit
import DontsToolCore
import SwiftUI

struct LauncherPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? 0.99 : 1)
            .animation(Motion.hoverEasing, value: configuration.isPressed)
    }
}

/// 键盘键帽：↑↓、↵、esc 等，克制的按键质感。
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.keycapFont)
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: Metrics.keycapCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.keycapCornerRadius)
                    .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
            )
    }
}

/// 结果行右侧的动作提示：选中或悬停时出现，低调中性。
struct ActionCapsule: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
                .font(Theme.capsuleFont)
                .foregroundStyle(Theme.secondary)
            KeyCap(text: "↵")
        }
    }
}

/// 关键词工具的快捷键标签：json、tr 等，纯等宽弱化文本。
struct ShortcutTag: View {
    let keyword: String

    var body: some View {
        Text(keyword)
            .font(Theme.keycapFont)
            .foregroundStyle(Theme.tertiary)
    }
}

/// 20pt 克制图标：应用/文件用真实图标，工具符号统一用单色线形图标（无彩色底块）。
struct IconTile: View {
    let icon: ItemIcon
    var size: CGFloat = Metrics.iconSize
    var symbolSize: CGFloat = 14
    var glyphSize: CGFloat = 11

    var body: some View {
        Group {
            switch icon {
            case .application(let path), .file(let path):
                Image(nsImage: FileIconImage.image(for: path))
                    .resizable()
                    .scaledToFit()
            case .symbol(let name, _):
                Image(systemName: name)
                    .font(.system(size: symbolSize, weight: .regular))
                    .foregroundStyle(Theme.secondary)
            case .glyph(let text, _):
                Text(text)
                    .font(.system(size: glyphSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
            case .image(let path):
                if let image = FileIconImage.pluginImage(for: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: symbolSize, weight: .regular))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(width: size, height: size)
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
            isDefaultList ? "最近工具" : "工具"
        case .file:
            "文件"
        case .web:
            "网页"
        case .shortcut:
            "网址快捷入口"
        }
    }
}

/// 极简 30pt 底栏：产品名 + 实时状态 / 克制更新胶囊 + 键位说明。
struct PanelFooterView: View {
    let statusText: String?
    let isWarning: Bool
    let isActionPanelOpen: Bool
    var onShowActions: (() -> Void)? = nil
    var hasActions = true
    var selectedItem: SearchItem? = nil
    var availableUpdateVersion: String? = nil
    var onOpenUpdate: (() -> Void)? = nil
    var onDismissUpdate: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text("DontsTool")
                .font(Theme.footerFont.weight(.medium))
                .foregroundStyle(Theme.tertiary)
            if let statusText {
                Text("·")
                    .foregroundStyle(Theme.tertiary)
                Text(statusText)
                    .font(Theme.footerFont)
                    .foregroundStyle(isWarning ? Theme.warning : Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if !isActionPanelOpen, let availableUpdateVersion {
                updatePill(version: availableUpdateVersion)
            }
            Spacer(minLength: 8)
            if isActionPanelOpen {
                legend(keys: ["↑↓"], label: "选择")
                spacerDot
                legend(keys: ["↵"], label: "执行")
                spacerDot
                legend(keys: ["esc"], label: "返回")
            } else {
                if selectedItem?.fileAction(.copyPath) != nil {
                    legend(keys: ["↵"], label: "打开")
                    if selectedItem?.fileAction(.reveal) != nil {
                        spacerDot
                        legend(keys: ["⌘↵"], label: "定位")
                    }
                    spacerDot
                    legend(keys: ["⌘⇧C"], label: "复制路径")
                } else {
                    legend(keys: ["↑↓"], label: "选择")
                    spacerDot
                    legend(keys: ["↵"], label: "执行")
                }
                spacerDot
                Button { onShowActions?() } label: {
                    legend(keys: ["⌘K"], label: "操作")
                }
                .buttonStyle(.plain)
                .disabled(!hasActions)
                .help("查看当前结果的所有操作（⌘K）")
                .accessibilityLabel("查看所有操作")
                spacerDot
                legend(keys: ["esc"], label: "关闭")
            }
        }
        .padding(.horizontal, Metrics.panelHorizontalInset)
        .frame(height: Metrics.footerHeight)
        .background(Theme.footerBase)
        .overlay(alignment: .top) { Theme.separator.frame(height: 0.5) }
    }

    private var spacerDot: some View {
        Text("·")
            .font(Theme.footerFont)
            .foregroundStyle(Theme.tertiary.opacity(0.5))
    }

    private func updatePill(version: String) -> some View {
        HStack(spacing: 4) {
            Button {
                onOpenUpdate?()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                    Text("新版本 \(version)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("发现新版本 \(version)，点击查看更新并安装")
            .accessibilityLabel("发现新版本 \(version)，点击查看更新")

            Button {
                onDismissUpdate?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("暂时隐藏此版本更新提示")
            .accessibilityLabel("暂时隐藏新版本 \(version) 提示")
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .background(Theme.accentFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accentBorder, lineWidth: 0.5))
        .fixedSize(horizontal: true, vertical: false)
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
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// ⌘K 动作面板：中性原生菜单样式。
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
        .frame(width: 240, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.popoverBase)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
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
                    .foregroundStyle(isSelected ? Theme.ink : Theme.secondary)
                Text(action.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                if isSelected {
                    KeyCap(text: "↵")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(LauncherPressStyle())
        .onHover { isHovered = $0 }
        .animation(Motion.hoverEasing, value: isHovered)
        .animation(Motion.paletteEasing, value: isSelected)
        .accessibilityLabel(action.title)
    }

    private var rowBackground: Color {
        if isSelected { return Theme.selection }
        if isHovered { return Theme.rowHover }
        return .clear
    }
}

/// 复制/执行反馈 Toast：极简原生浮层。
struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.success)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
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
    }
}
