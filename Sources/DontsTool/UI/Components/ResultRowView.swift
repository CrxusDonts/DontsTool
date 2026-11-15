import DontsToolCore
import SwiftUI

/// 单条搜索结果：图标块 + 标题/副标题 + 动作胶囊或关键词标签。
struct ResultRowView: View {
    let item: SearchItem
    let keyword: String?
    let isSelected: Bool
    var drawsSelection = true
    let onExecute: () -> Void
    var onSecondaryExecute: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onExecute) {
                HStack(spacing: Metrics.rowIconSpacing) {
                    IconTile(icon: item.icon)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(Theme.rowTitleFont)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minWidth: 40, alignment: .leading)
                            if let badge = item.badge {
                                Text(badge.text)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1).truncationMode(.tail)
                                    .foregroundStyle(badge.tint.style.foreground)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
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
                    trailing.frame(width: 88, alignment: .trailing)
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
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
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
            .overlay(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
                .strokeBorder(Theme.selectionBorder, lineWidth: 1))
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.accent).frame(width: 3, height: 20).padding(.leading, 1)
            }
    }
}
