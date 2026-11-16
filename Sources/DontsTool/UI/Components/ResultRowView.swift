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

    @State private var isHovered = false

    private var prefersInlineSubtitle: Bool {
        guard item.badge == nil else { return false }
        switch item.icon {
        case .symbol, .glyph:
            return true
        case .application, .file:
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

                    trailing.frame(width: 100, alignment: .trailing)
                }
                .frame(height: Metrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(LauncherPressStyle())
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let action = fileSecondaryAction, let onSecondaryExecute {
                Button(action: onSecondaryExecute) {
                    Image(systemName: action.symbol ?? "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(LauncherPressStyle())
                .help("\(action.title)（⌘Enter）")
                .accessibilityLabel("\(action.title)：\(item.title)")
                .opacity(isSelected || isHovered ? 1 : 0)
                .allowsHitTesting(isSelected || isHovered)
                .accessibilityHidden(!isSelected && !isHovered)
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

    private var fileSecondaryAction: ItemAction? {
        guard case .file = item.icon else { return nil }
        return item.secondaryAction
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
                tileIcon
                    .frame(width: 20, height: 20)
                Text(item.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
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

    @ViewBuilder
    private var tileIcon: some View {
        switch item.icon {
        case .application(let path), .file(let path):
            Image(nsImage: FileIconImage.image(for: path))
                .resizable()
                .scaledToFit()
        case .symbol(let name, _):
            Image(systemName: name)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.secondary)
        case .glyph(let text, _):
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.secondary)
        }
    }
}
