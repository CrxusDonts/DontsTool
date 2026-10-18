import DontsToolCore
import SwiftUI

/// 单条搜索结果：图标块 + 标题/副标题 + 动作胶囊或关键词标签。
struct ResultRowView: View {
    let item: SearchItem
    let keyword: String?
    let isSelected: Bool
    let onExecute: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onExecute) {
            HStack(spacing: Metrics.rowIconSpacing) {
                IconTile(icon: item.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Theme.rowTitleFont)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.rowSubtitleFont)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, Metrics.rowHorizontalInset)
            .frame(height: Metrics.rowHeight)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: Metrics.rowCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
                    .strokeBorder(isSelected ? Theme.selectionBorder : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.easeOut, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
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
        return "\(item.title)，\(item.subtitle ?? "")\(action)"
    }

    private var rowBackground: Color {
        if isSelected { return Theme.selection }
        if isHovered { return Theme.rowHover }
        return .clear
    }
}
