import Foundation

/// Local lookup only; URLs are opened exclusively by an explicit item action.
@MainActor
public final class WebsiteShortcutProvider: ToolProvider {
    public let id = "website"
    public let displayName = "网址快捷入口"
    public var keywords: [String] { store.configuration.groups.map(\.keyword) }
    public let priority = 250
    public var isEnabled = true
    public private(set) var statusNotice: String?
    private let store: WebsiteShortcutStore
    private let opener: any URLOpening
    private let feedback: any FeedbackProviding
    private let prefill: any QueryPrefilling

    public init(store: WebsiteShortcutStore, opener: any URLOpening, feedback: any FeedbackProviding, prefill: any QueryPrefilling) {
        self.store = store; self.opener = opener; self.feedback = feedback; self.prefill = prefill
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        statusNotice = nil
        guard isEnabled else { return [] }
        switch context.mode {
        case .keyword(let providerID, let keyword, _) where providerID == id:
            guard let group = store.configuration.groups.first(where: { $0.keyword == keyword }) else { return [] }
            let items = matches(group, query: context.query.trimmingCharacters(in: .whitespacesAndNewlines))
            if items.isEmpty { statusNotice = group.items.isEmpty ? "这个分组还没有网址，请在设置中添加" : "没有匹配的网址，请检查简称或在设置中添加" }
            return items
        case .global:
            let query = context.query
            var items: [SearchItem] = []
            for group in store.configuration.groups {
                if query.isEmpty || FuzzyMatcher.score(query: query, candidate: group.name) != nil || FuzzyMatcher.score(query: query, candidate: group.keyword) != nil {
                    let prefill = self.prefill
                    items.append(SearchItem(providerID: id, group: .shortcut, title: group.name,
                        subtitle: "\(group.items.count) 个网址 · 输入 \(group.keyword) 项目简称", icon: .symbol(name: "link", tint: .teal),
                        score: 1000, canonicalKey: "website-group:\(group.keyword)", actions: [ItemAction(id: "website.prefill", title: "进入分组", presentation: .keepPanelOpen) { prefill.prefill(group.keyword + " ") }], keyword: group.keyword))
                }
                if !query.isEmpty { items.append(contentsOf: matches(group, query: query)) }
            }
            return items
        default: return []
        }
    }

    private func matches(_ group: WebsiteShortcutGroup, query: String) -> [SearchItem] {
        group.items.compactMap { item in
            let score: Double
            if query.isEmpty { score = 500 }
            else {
                let candidates = [item.key] + item.aliases + [item.name]
                guard let best = candidates.compactMap({ FuzzyMatcher.score(query: query, candidate: $0) }).max() else { return nil }
                if WebsiteShortcutConfiguration.lookupKey(query) == WebsiteShortcutConfiguration.lookupKey(item.key) { score = 3000 }
                else if item.aliases.contains(where: { WebsiteShortcutConfiguration.lookupKey(query) == WebsiteShortcutConfiguration.lookupKey($0) }) { score = 2500 }
                else { score = best }
            }
            guard let url = URL(string: item.url) else { return nil }
            let opener = self.opener; let feedback = self.feedback
            return SearchItem(providerID: id, group: .shortcut, title: item.name,
                subtitle: "\(group.keyword) \(item.key) · \(item.url)", icon: .symbol(name: "link", tint: .teal), score: score,
                canonicalKey: "website:\(group.keyword):\(item.key)", actions: [ItemAction(id: "website.open", title: "打开网址") {
                    do { try opener.open(url) } catch { feedback.show(error.localizedDescription) }
                }])
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
