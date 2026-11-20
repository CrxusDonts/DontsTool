import DontsToolCore
import SwiftUI

struct GuideSettingsTabView: View {
    @ObservedObject var settings: SettingsStore
    @Binding var searchQuery: String
    let onTryQuery: (String) -> Void

    @State private var selectedCategory: FeatureGuideCategory? = nil

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hotKeyDisplay: String {
        HotKeyFormatter.displayString(for: settings.hotKey)
    }

    private var filteredShortcuts: [FeatureGuideShortcut] {
        guard selectedCategory == nil || selectedCategory == .shortcuts else { return [] }
        let all = FeatureGuideCatalog.shortcutRows(hotKeyDisplay: hotKeyDisplay)
        guard !trimmedQuery.isEmpty else { return all }
        let lower = trimmedQuery.lowercased()
        return all.filter { row in
            row.title.lowercased().contains(lower)
                || row.detail.lowercased().contains(lower)
                || row.keyCap.lowercased().contains(lower)
                || FuzzyMatcher.score(query: trimmedQuery, candidate: row.title) != nil
        }
    }

    private var filteredEntries: [FeatureGuideEntry] {
        if selectedCategory == .shortcuts { return [] }
        return FeatureGuideCatalog.entries(in: selectedCategory, matching: trimmedQuery)
    }

    private var groupedEntries: [(category: FeatureGuideCategory, entries: [FeatureGuideEntry])] {
        if let selectedCategory {
            let items = filteredEntries
            return items.isEmpty ? [] : [(selectedCategory, items)]
        }
        return FeatureGuideCategory.allCases.compactMap { category in
            let items = filteredEntries.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchAndFilterHeader

            if filteredShortcuts.isEmpty && groupedEntries.isEmpty {
                emptySearchState
            } else {
                if !filteredShortcuts.isEmpty {
                    shortcutsSection
                }
                ForEach(groupedEntries, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: group.category.symbol)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.tertiary)
                            Text(group.category.rawValue)
                                .font(Theme.sectionCaptionFont)
                                .foregroundStyle(Theme.tertiary)
                        }
                        .padding(.horizontal, 4)

                        VStack(spacing: 10) {
                            ForEach(group.entries) { entry in
                                GuideEntryCardView(
                                    entry: entry,
                                    isDisabled: isProviderDisabled(entry.providerID),
                                    onTryQuery: onTryQuery
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Search & Category Filter

    private var searchAndFilterHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiary)
                TextField("搜索功能、关键词、快捷键或用法（如 端口、无痕、终端、划词）…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.glassCardBorder, lineWidth: 0.75)
            )

            HStack(spacing: 6) {
                categoryChip(title: "全部", symbol: "square.grid.2x2", isSelected: selectedCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(FeatureGuideCategory.allCases) { category in
                    categoryChip(
                        title: category.rawValue,
                        symbol: category.symbol,
                        isSelected: selectedCategory == category
                    ) {
                        selectedCategory = category
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func categoryChip(title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isSelected ? Theme.accentFill : Theme.controlFill.opacity(0.6),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Theme.accentBorder : Theme.controlBorder.opacity(0.6), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shortcuts Grid

    private var shortcutsSection: some View {
        SettingsGroup(caption: "快捷键与交互") {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 8
            ) {
                ForEach(filteredShortcuts) { row in
                    HStack(alignment: .top, spacing: 9) {
                        KeyCap(text: row.keyCap)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text(row.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.controlFill.opacity(0.42), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(10)
        }
    }

    private var emptySearchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("没有找到匹配「\(trimmedQuery)」的功能说明")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("试试搜索关键词如 chrome、tf、kill、note、划词 或 快捷键")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
            SettingsButton(title: "重置筛选") {
                searchQuery = ""
                selectedCategory = nil
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius)
                .strokeBorder(Theme.glassCardBorder, lineWidth: 0.5)
        )
    }

    private func isProviderDisabled(_ providerID: ProviderID?) -> Bool {
        guard let providerID else { return false }
        return !settings.isProviderEnabled(providerID.rawValue)
    }
}

private struct GuideEntryCardView: View {
    let entry: FeatureGuideEntry
    let isDisabled: Bool
    let onTryQuery: (String) -> Void

    var body: some View {
        let tintStyle = entry.tint.style
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tintStyle.foreground)
                    .frame(width: 26, height: 26)
                    .background(tintStyle.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(tintStyle.border, lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        if isDisabled {
                            Text("当前已关闭")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.warning)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Theme.warning.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(entry.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if !entry.keywords.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(entry.keywords.prefix(4)), id: \.self) { keyword in
                            ShortcutTag(keyword: keyword)
                        }
                    }
                }
            }

            // Examples
            if !entry.examples.isEmpty {
                VStack(spacing: 5) {
                    ForEach(entry.examples) { example in
                        HStack(spacing: 10) {
                            Text(example.query.isEmpty ? "直接呼出" : example.query.trimmingCharacters(in: .whitespaces))
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
                                )
                                .fixedSize()

                            Text(example.label)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if example.canTryInLauncher {
                                Button {
                                    onTryQuery(example.query)
                                } label: {
                                    HStack(spacing: 3) {
                                        Text("试一下")
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 9.5, weight: .semibold))
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                                .help("唤起启动器并填入「\(example.query.isEmpty ? "首页" : example.query)」")
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Theme.controlFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }

            // Tips
            if !entry.tips.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.tertiary)
                                .padding(.top, 2)
                            Text(tip)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(13)
        .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius)
                .strokeBorder(Theme.glassCardBorder, lineWidth: 0.5)
        )
    }
}
