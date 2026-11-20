import Foundation

@MainActor
public final class HelpGuideProvider: ToolProvider {
    public let id = "helpGuide"
    public let displayName = "使用指南"
    public let priority = 160
    public let phase = SearchPhase.fast
    public var isEnabled: Bool = true
    public var statusNotice: String? { nil }

    public var keywords: [String] {
        let unavailable = Set(unavailableKeywords().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return ["help", "?", "？", "帮助", "说明", "指南"].filter { !unavailable.contains($0) }
    }

    private let openGuide: @MainActor (String) -> Void
    private let prefill: (any QueryPrefilling)?
    private let unavailableKeywords: @MainActor () -> Set<String>

    public init(
        openGuide: @escaping @MainActor (String) -> Void,
        prefill: (any QueryPrefilling)? = nil,
        unavailableKeywords: @escaping @MainActor () -> Set<String> = { [] }
    ) {
        self.openGuide = openGuide
        self.prefill = prefill
        self.unavailableKeywords = unavailableKeywords
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled, !Task.isCancelled else { return [] }

        switch context.mode {
        case .global:
            let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return [] }
            let aliases = ["help", "guide", "manual", "帮助", "说明", "使用指南", "功能说明", "快捷键", "文档"]
            guard aliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) else {
                return []
            }
            return [openGuideEntry(query: "", score: 1750)]

        case .keyword(let providerID, let keyword, _) where providerID == id:
            guard keywords.contains(keyword.lowercased()) else { return [] }
            let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = FeatureGuideCatalog.entries(matching: query)

            var items: [SearchItem] = [openGuideEntry(query: query, score: query.isEmpty ? 2600 : 2200)]
            for (index, entry) in matches.enumerated() {
                items.append(makeEntryItem(entry, query: query, score: 2500 - Double(index)))
            }
            return Array(items.prefix(20))

        default:
            return []
        }
    }

    private func openGuideEntry(query: String, score: Double) -> SearchItem {
        let openGuide = self.openGuide
        let title = query.isEmpty ? "打开 DontsTool 使用指南" : "在使用指南中搜索「\(query)」"
        let subtitle = query.isEmpty
            ? "查看所有功能的触发关键词、用法示例与快捷键速查"
            : "在设置窗口的「使用指南」中定位相关功能与示例"
        return SearchItem(
            providerID: id,
            group: .tool,
            title: title,
            subtitle: subtitle,
            icon: .symbol(name: "book.closed", tint: .blue),
            score: score,
            canonicalKey: "help-guide:open",
            actions: [
                ItemAction(id: "help.openGuide", title: "打开使用指南", presentation: .openWindow, symbol: "book.closed") {
                    openGuide(query)
                }
            ],
            keyword: keywords.first ?? "help"
        )
    }

    private func makeEntryItem(_ entry: FeatureGuideEntry, query: String, score: Double) -> SearchItem {
        let openGuide = self.openGuide
        let prefill = self.prefill
        let triggerHint = entry.keywords.isEmpty ? "" : "[\(entry.keywords.prefix(3).joined(separator: " / "))] "
        let firstExample = entry.examples.first.map { "例：\($0.query.trimmingCharacters(in: .whitespaces))（\($0.label)）" }
        let subtitle = firstExample.map { "\(triggerHint)\($0)" } ?? "\(triggerHint)\(entry.summary)"

        var actions: [ItemAction] = [
            ItemAction(id: "help.entry.open.\(entry.id)", title: "在使用指南中查看", presentation: .openWindow, symbol: "book.closed") {
                openGuide(query.isEmpty ? entry.title : query)
            }
        ]
        if let tryQuery = entry.tryQuery, !tryQuery.isEmpty, let prefill {
            actions.append(ItemAction(id: "help.entry.try.\(entry.id)", title: "试用示例：\(tryQuery)", presentation: .keepPanelOpen, symbol: "play.circle") {
                prefill.prefill(tryQuery)
            })
        }

        return SearchItem(
            providerID: id,
            group: .tool,
            title: entry.title,
            subtitle: subtitle,
            icon: .symbol(name: entry.symbol, tint: entry.tint),
            score: score,
            canonicalKey: "help-guide:entry:\(entry.id)",
            actions: actions,
            keyword: entry.keywords.first,
            badge: SearchItemBadge(text: entry.category.rawValue, tint: entry.tint)
        )
    }
}
