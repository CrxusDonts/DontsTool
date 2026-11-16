import AppKit
import DontsToolCore
import SwiftUI

/// 启动器面板内容：Liquid Glass 紧凑外壳 + 搜索头 + 分组结果 + 底栏 + Toast。
struct LauncherPanelView: View {
    @ObservedObject var model: LauncherPanelModel
    let searchField: SearchField
    @ObservedObject var settings: SettingsStore
    let onOpenSettings: () -> Void
    let onExecute: (_ index: Int, _ secondary: Bool) -> Void
    let onExecuteAction: (Int) -> Void
    let onClearQuery: () -> Void
    let onClearContent: () -> Void
    let onShowActions: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
            if let content = model.attachedContent {
                ContentAttachmentView(content: content, onClear: onClearContent)
                    .transition(.opacity.combined(with: .offset(y: Motion.reduceMotion ? 0 : -6)))
            }
            resultList
            PanelFooterView(
                statusText: model.statusText,
                isWarning: model.statusIsWarning,
                isActionPanelOpen: model.isActionPanelOpen,
                onShowActions: onShowActions,
                hasActions: !model.actionItems.isEmpty
            )
        }
        .frame(width: Metrics.panelSize.width, height: Metrics.panelSize.height)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.panelCornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.panelHighlight, Theme.panelBorder, Theme.panelBorder],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        )
        .overlay(alignment: .bottomTrailing) {
            if model.isActionPanelOpen {
                ActionPaletteView(
                    itemTitle: model.selectedItem?.title ?? "",
                    actions: model.actionItems,
                    selectedIndex: model.selectedActionIndex,
                    onExecute: onExecuteAction
                )
                .padding(.trailing, 10)
                .padding(.bottom, Metrics.footerHeight + 8)
                .transition(.opacity.combined(with: .offset(y: Motion.reduceMotion ? 0 : 4))
                    .combined(with: .scale(scale: Motion.reduceMotion ? 1 : 0.985, anchor: .bottomTrailing)))
            }
        }
        .animation(Motion.paletteEasing, value: model.isActionPanelOpen)
        .animation(Motion.contentEasing, value: model.attachedContent)
        .overlay(alignment: .bottom) { toast }
    }

    private var panelBackground: some View {
        ZStack {
            if !reduceTransparency {
                RoundedRectangle(cornerRadius: Metrics.panelCornerRadius).fill(.ultraThinMaterial)
            }
            RoundedRectangle(cornerRadius: Metrics.panelCornerRadius)
                .fill(reduceTransparency ? Theme.panelSolid : Theme.panelBase)
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
                            sectionHeader(section)
                                .id("section-\(section.group.rawValue)")
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                                let index = section.startIndex + offset
                                ResultRowView(
                                    item: item,
                                    keyword: item.keyword,
                                    isSelected: index == model.selectedIndex,
                                    drawsSelection: false,
                                    onExecute: { onExecute(index, false) },
                                    onSecondaryExecute: { onExecute(index, true) }
                                )
                                .id(item.id)
                                .anchorPreference(key: SelectionBoundsKey.self, value: .bounds) { [item.id: $0] }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.listHorizontalInset)
                    .padding(.vertical, Metrics.listVerticalInset)
                    .backgroundPreferenceValue(SelectionBoundsKey.self) { bounds in
                        GeometryReader { geometry in
                            if let id = model.selectedItem?.id, let anchor = bounds[id] {
                                let frame = geometry[anchor]
                                LauncherSelectionSurface()
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                                    .animation(Motion.selectionGlide, value: model.selectedIndex)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selectedIndex) { _, _ in
                guard let id = model.selectedItem?.id else { return }
                withAnimation(Motion.listEasing) {
                    proxy.scrollTo(id)
                }
            }
            .onChange(of: model.items.map(\.id)) { _, _ in
                guard let first = model.sections.first else { return }
                proxy.scrollTo("section-\(first.group.rawValue)", anchor: .top)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func sectionHeader(_ section: LauncherPanelModel.Section) -> some View {
        if section.group == .app, model.isDefaultList {
            HStack {
                Text(settings.applicationSortOrder.displayName).font(Theme.groupCaptionFont)
                Spacer()
                Menu {
                    ForEach(SettingsStore.ApplicationSortOrder.allCases) { order in
                        Button {
                            settings.setApplicationSortOrder(order)
                        } label: {
                            if settings.applicationSortOrder == order {
                                Label(order.displayName, systemImage: "checkmark")
                            } else { Text(order.displayName) }
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("应用排序：\(settings.applicationSortOrder.displayName)")
            }
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, Metrics.captionHorizontalInset)
            .padding(.vertical, Metrics.captionVerticalInset + 1)
        } else if model.attachedContent != nil {
            Text("可用操作").font(Theme.groupCaptionFont).foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.captionHorizontalInset)
                .padding(.vertical, Metrics.captionVerticalInset + 1)
        } else { GroupHeader(group: section.group, isDefaultList: model.isDefaultList) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.attachedContent == nil ? "magnifyingglass" : "line.3.horizontal.decrease")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(model.attachedContent != nil ? "没有匹配的操作" : isBareFileQuery ? "输入文件名开始搜索" : "没有找到匹配结果")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text(model.attachedContent != nil ? "清空筛选词，或在设置中启用相关工具" : isFileSearchQuery ? "例如 file 报告，仅在此模式搜索文件名" : "试试应用名称、拼音，或 json 等关键词")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity).frame(minHeight: 240).padding(20)
    }

    private var isBareFileQuery: Bool {
        isFileSearchQuery && model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "file"
    }

    private var isFileSearchQuery: Bool { model.queryRoute?.providerID == ProviderID.file.rawValue }

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

private struct SelectionBoundsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// 紧凑搜索头：54pt 高度，放大镜 + 输入框 + 关键词胶囊 + 热键 + 设置按钮。
struct SearchHeaderView: View {
    let field: SearchField
    let hotKeyDisplay: String
    let badge: String?
    let hasQuery: Bool
    let onClearQuery: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
            SearchFieldRepresentable(field: field)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 6) {
                if hasQuery {
                    Button(action: onClearQuery) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
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
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: Metrics.gearButtonSize, height: Metrics.gearButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置")
                .accessibilityLabel("打开设置")
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 0.5, height: 20)
            }
        }
        .padding(.horizontal, Metrics.panelHorizontalInset)
        .frame(height: Metrics.headerHeight)
        .background(Theme.headerBase)
        .overlay(alignment: .bottom) {
            Theme.separator.frame(height: 0.5)
        }
    }
}

private struct ContentAttachmentView: View {
    let content: ContentDescriptor
    let onClear: () -> Void

    private var symbol: String {
        switch content.kind {
        case .json: "curlybraces"
        case .url: "link"
        case .text: "text.alignleft"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 6))
            Text(content.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text(content.summary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("移除内容（Esc）")
            .accessibilityLabel("移除附加内容")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
        .padding(.horizontal, Metrics.panelHorizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("已附加\(content.displayTitle)，\(content.summary)")
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
