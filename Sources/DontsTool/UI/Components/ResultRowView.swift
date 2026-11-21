import DontsToolCore
import SwiftUI

/// 单条紧凑搜索结果：Raycast × Spotlight 风格，纯中性选中态、单色工具图标与克制排版。
struct ResultRowView: View {
    let item: SearchItem
    let keyword: String?
    let isSelected: Bool
    var drawsSelection = true
    let onExecute: () -> Void
    var onSecondaryExecute: (() -> Void)? = nil
    var onCopyFilePath: (() -> Void)? = nil

    @State private var isHovered = false

    private var prefersInlineSubtitle: Bool {
        guard item.badge == nil else { return false }
        switch item.icon {
        case .symbol, .glyph:
            return true
        case .application, .file, .image:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onExecute) {
                HStack(spacing: Metrics.rowIconSpacing) {
                    IconTile(icon: item.icon)

                    if prefersInlineSubtitle {
                        HStack(spacing: 8) {
                            Text(item.title)
                                .font(Theme.rowTitleFont)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(Theme.rowSubtitleFont)
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(subtitle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(Theme.rowTitleFont)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(minWidth: 36, alignment: .leading)
                                if let badge = item.badge {
                                    Text(badge.text)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .foregroundStyle(badge.tint.style.foreground)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .frame(maxWidth: 132)
                                        .fixedSize(horizontal: true, vertical: true)
                                        .background(badge.tint.style.background, in: RoundedRectangle(cornerRadius: 4))
                                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(badge.tint.style.border, lineWidth: 0.5))
                                        .layoutPriority(1)
                                        .help(badge.text)
                                        .accessibilityHidden(true)
                                }
                            }
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(Theme.rowSubtitleFont)
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(subtitle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    trailing.frame(width: item.fileAction(.copyPath) != nil ? 52 : 100, alignment: .trailing)
                }
                .frame(height: Metrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(LauncherPressStyle())
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let action = item.fileAction(.reveal), let onSecondaryExecute {
                fileButton(action, title: "定位", shortcut: "⌘Enter", execute: onSecondaryExecute)
            }
            if let action = item.fileAction(.copyPath), let onCopyFilePath {
                fileButton(action, title: "复制路径", shortcut: "⌘⇧C", execute: onCopyFilePath)
            }
        }
        .padding(.horizontal, Metrics.rowHorizontalInset)
        .frame(height: Metrics.rowHeight)
        .background { selectionBackground }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius))
        .onHover { isHovered = $0 }
        .animation(Motion.hoverEasing, value: isHovered)
        .accessibilityElement(children: .contain)
    }

    private func fileButton(_ action: ItemAction, title: String, shortcut: String, execute: @escaping () -> Void) -> some View {
        Button(action: execute) {
            Label(title, systemImage: action.symbol ?? "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(LauncherPressStyle())
        .help("\(action.title)（\(shortcut)）")
        .accessibilityLabel("\(action.title)：\(item.title)")
        .opacity(isSelected || isHovered ? 1 : 0)
        .allowsHitTesting(isSelected || isHovered)
        .accessibilityHidden(!isSelected && !isHovered)
    }

    @ViewBuilder
    private var trailing: some View {
        if isSelected || isHovered {
            if let action = item.primaryAction {
                ActionCapsule(title: action.title)
                    .transition(.opacity)
            }
        } else if let keyword {
            ShortcutTag(keyword: keyword)
        }
    }

    private var accessibilityText: String {
        let action = item.primaryAction.map { "，\($0.title)" } ?? ""
        let badge = item.badge.map { "，环境：\($0.text)" } ?? ""
        return "\(item.title)\(badge)，\(item.subtitle ?? "")\(action)"
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected, drawsSelection {
            LauncherSelectionSurface()
        } else if isHovered, !isSelected {
            RoundedRectangle(cornerRadius: Metrics.rowCornerRadius).fill(Theme.rowHover)
        }
    }
}

struct LauncherSelectionSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
            .fill(Theme.selection)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
                    .strokeBorder(Theme.selectionBorder, lineWidth: 0.5)
            )
    }
}

/// 空搜索态横向应用胶囊：[20pt 真实图标] 应用名，与下方列表共享完全一致的选中态与圆角。
struct AppDockTileView: View {
    let item: SearchItem
    let isSelected: Bool
    let onExecute: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onExecute) {
            HStack(spacing: 8) {
                IconTile(icon: item.icon, size: 20)
                Text(item.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.appDockTileHeight)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
                    .fill(isSelected ? Color.clear : (isHovered ? Theme.rowHover : Theme.controlFill.opacity(0.6)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
                    .strokeBorder(isSelected ? Color.clear : Theme.separator, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius))
        }
        .buttonStyle(LauncherPressStyle())
        .onHover { isHovered = $0 }
        .animation(Motion.hoverEasing, value: isHovered)
        .help(item.subtitle.map { "\(item.title)\n\($0)" } ?? item.title)
        .accessibilityLabel("\(item.title)，打开")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 空搜索态下的紧凑工具网格卡片：单色图标 + 简短标题，大幅减少工具区纵向占用。
struct ToolGridTileView: View {
    let item: SearchItem
    let isSelected: Bool
    let onExecute: () -> Void
    @State private var isHovered = false

    private var compactTitle: String {
        switch item.title {
        case "JSON 工具", "JSON 工作台": return "JSON"
        case "Base64 编解码": return "Base64"
        case "URL 编解码": return "URL"
        case "时间戳转换": return "时间戳"
        case "UUID 生成器": return "UUID"
        case "Google Chrome": return "Chrome"
        case "IDEA 项目": return "IDEA"
        case "Gemini 提问": return "Gemini"
        case "终端与访达": return "终端访达"
        default: return item.title
        }
    }

    var body: some View {
        Button(action: onExecute) {
            HStack(spacing: 7) {
                IconTile(icon: item.icon, size: 18, symbolSize: 15, glyphSize: 11.5)
                Text(compactTitle)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let keyword = item.keyword, !keyword.isEmpty {
                    Text(keyword)
                        .font(Theme.keycapFont)
                        .foregroundStyle(isSelected ? Theme.secondary : Theme.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.toolGridTileHeight)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
                    .fill(isSelected ? Color.clear : (isHovered ? Theme.rowHover : Theme.controlFill.opacity(0.45)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
                    .strokeBorder(isSelected ? Color.clear : Theme.separator, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius))
        }
        .buttonStyle(LauncherPressStyle())
        .onHover { isHovered = $0 }
        .animation(Motion.hoverEasing, value: isHovered)
        .help(item.subtitle.map { "\(item.title)\n\($0)" } ?? item.title)
        .accessibilityLabel("\(item.title)，\(item.primaryAction?.title ?? "打开")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
