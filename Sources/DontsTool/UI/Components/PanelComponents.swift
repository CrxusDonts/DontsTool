import AppKit
import DontsToolCore
import SwiftUI

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
            Text("↵").font(.system(size: 10))
        }
        .font(Theme.capsuleFont)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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

/// 32pt 图标块：应用/文件用系统图标，符号与字形用着色块。
struct IconTile: View {
    let icon: ItemIcon

    var body: some View {
        Group {
            switch icon {
            case .application(let path), .file(let path):
                Image(nsImage: FileIconImage.image(for: path))
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            case .symbol(let name, let tint):
                Image(systemName: name)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(tint.style.foreground)
            case .glyph(let text, let tint):
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
            Theme.controlFill
        }
    }

    private var tileBorder: Color {
        switch icon {
        case .symbol(_, let tint), .glyph(_, let tint):
            tint.style.border
        default:
            Theme.separator
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

/// 底栏：产品标识 + 实时状态 + 键位说明。
struct PanelFooterView: View {
    let statusText: String?
    let isWarning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
            Text("DontsTool")
                .font(Theme.footerFont)
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
            HStack(spacing: 6) {
                legend(keys: ["↑↓"], label: "选择")
                Text("·").foregroundStyle(Theme.separator)
                legend(keys: ["↵"], label: "执行")
                Text("·").foregroundStyle(Theme.separator)
                legend(keys: ["esc"], label: "关闭")
            }
        }
        .padding(.horizontal, Metrics.panelHorizontalInset)
        .frame(height: Metrics.footerHeight)
        .background(Theme.footerBase)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
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

/// 复制/执行反馈 Toast：非模态，自动消失。
struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.success)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.toastBackground, in: RoundedRectangle(cornerRadius: Metrics.toastCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.toastCornerRadius)
                .strokeBorder(Theme.toastBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
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
