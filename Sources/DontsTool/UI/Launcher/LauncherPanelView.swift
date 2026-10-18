import AppKit
import DontsToolCore
import SwiftUI

/// 启动器面板内容：搜索头 + 分组结果 + 底栏 + Toast。
struct LauncherPanelView: View {
    @ObservedObject var model: LauncherPanelModel
    let searchField: SearchField
    let onOpenSettings: () -> Void
    let onExecute: (_ index: Int, _ secondary: Bool) -> Void
    let onClearQuery: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SearchHeaderView(
                field: searchField,
                hotKeyDisplay: model.hotKeyDisplay,
                badge: model.queryBadge,
                hasQuery: !model.queryText.isEmpty,
                onClearQuery: onClearQuery,
                onOpenSettings: onOpenSettings
            )
            resultList
            PanelFooterView(statusText: model.statusText, isWarning: model.statusIsWarning)
        }
        .frame(width: Metrics.panelSize.width, height: Metrics.panelSize.height)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.panelCornerRadius)
                .strokeBorder(Theme.panelBorder, lineWidth: 1)
        )
        .overlay(alignment: .bottom) { toast }
    }

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.panelCornerRadius)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: Metrics.panelCornerRadius)
                .fill(Theme.panelBase)
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                if model.showsEmptyState {
                    emptyState
                } else {
                    VStack(spacing: Metrics.listSpacing) {
                        ForEach(model.sections) { section in
                            GroupHeader(group: section.group, isDefaultList: model.isDefaultList)
                                .id("section-\(section.group.rawValue)")
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                                let index = section.startIndex + offset
                                ResultRowView(
                                    item: item,
                                    keyword: item.keyword,
                                    isSelected: index == model.selectedIndex,
                                    onExecute: { onExecute(index, false) }
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.listHorizontalInset)
                    .padding(.vertical, Metrics.listVerticalInset)
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selectedIndex) { _, _ in
                guard let id = model.selectedItem?.id else { return }
                withAnimation(Motion.listEasing) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: model.items.map(\.id)) { _, _ in
                guard let first = model.sections.first else { return }
                proxy.scrollTo("section-\(first.group.rawValue)", anchor: .top)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        Text("没有找到结果")
            .accessibilityLabel("没有找到结果")
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
    }

    @ViewBuilder
    private var toast: some View {
        if let message = model.toastMessage {
            ToastView(message: message)
                .padding(.bottom, Metrics.toastBottomInset)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(Motion.enterEasing, value: model.toastMessage)
        }
    }
}

/// 搜索头：放大镜 + 输入框 + 关键词胶囊 + 热键 + 设置按钮。
struct SearchHeaderView: View {
    let field: SearchField
    let hotKeyDisplay: String
    let badge: String?
    let hasQuery: Bool
    let onClearQuery: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.tertiary)
            SearchFieldRepresentable(field: field)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                if hasQuery {
                    Button(action: onClearQuery) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空")
                }
                if let badge {
                    ShortcutTag(keyword: badge)
                }
                KeyCap(text: hotKeyDisplay)
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: Metrics.gearButtonSize, height: Metrics.gearButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置")
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 1, height: 24)
            }
        }
        .padding(.horizontal, Metrics.panelHorizontalInset)
        .frame(height: Metrics.headerHeight)
        .background(Theme.headerBase)
        .overlay(alignment: .bottom) {
            Theme.separator.frame(height: 1)
        }
    }
}

/// 复用已验证键盘/IME 行为的 AppKit 搜索框。
struct SearchFieldRepresentable: NSViewRepresentable {
    let field: SearchField

    func makeNSView(context: Context) -> SearchField {
        field
    }

    func updateNSView(_ nsView: SearchField, context: Context) {}
}
