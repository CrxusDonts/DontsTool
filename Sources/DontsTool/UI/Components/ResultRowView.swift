import DontsToolCore
import SwiftUI

/// 单条紧凑搜索结果：26pt 图标块 + 标题/环境徽章/副标题 + 动作胶囊或快捷键标签。
struct ResultRowView: View {
    let item: SearchItem
    let keyword: String?
    let isSelected: Bool
    var drawsSelection = true
    let onExecute: () -> Void
    var onSecondaryExecute: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onExecute) {
                HStack(spacing: Metrics.rowIconSpacing) {
                    IconTile(icon: item.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(Theme.rowTitleFont)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minWidth: 36, alignment: .leading)
                            if let badge = item.badge {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(badge.tint.style.foreground)
                                        .frame(width: 5, height: 5)
                                    Text(badge.text)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .foregroundStyle(badge.tint.style.foreground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .frame(maxWidth: 132)
                                .fixedSize(horizontal: true, vertical: true)
                                .background(badge.tint.style.background, in: Capsule())
                                .overlay(Capsule().strokeBorder(badge.tint.style.border, lineWidth: 0.5))
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
                    trailing.frame(width: 84, alignment: .trailing)
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
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24, height: 24)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
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
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2.5, height: 18)
                    .padding(.leading, 2)
            }
    }
}
