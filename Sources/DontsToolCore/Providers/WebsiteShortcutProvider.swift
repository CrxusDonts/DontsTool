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
        guard isEnabled, !Task.isCancelled else { return [] }
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
                    let addressCount = group.items.reduce(0) { $0 + max(1, $1.environments.count) * (1 + $1.pages.count) }
                    items.append(SearchItem(providerID: id, group: .shortcut, title: group.name,
                        subtitle: "\(group.items.count) 个系统 · \(addressCount) 个网址 · 输入 \(group.keyword) 项目简称", icon: .symbol(name: "link", tint: .teal),
                        score: 1000, canonicalKey: "website-group:\(group.keyword)", actions: [ItemAction(id: "website.prefill", title: "进入分组", presentation: .keepPanelOpen) { [weak self] in
                            guard self?.isEnabled == true, !Task.isCancelled else { return }
                            prefill.prefill(group.keyword + " ")
                        }], keyword: group.keyword))
                }
                if !query.isEmpty { items.append(contentsOf: matches(group, query: query)) }
            }
            return items
        default: return []
        }
    }

    private struct SystemSelection {
        let item: WebsiteShortcut
        let remainder: String
        let score: Double
        let exact: Bool
        let wordCount: Int
    }

    private func matches(_ group: WebsiteShortcutGroup, query: String) -> [SearchItem] {
        let lookup = normalizedLabel(query)
        let exactSystem = group.items.contains { item in
            ([item.key] + item.aliases).contains { normalizedLabel($0) == lookup }
        }
        let selections: [SystemSelection]
        if query.isEmpty || exactSystem {
            selections = group.items.compactMap { item in
                matchScore(item, query: query).map { SystemSelection(item: item, remainder: "", score: $0, exact: true, wordCount: 0) }
            }
        } else {
            let structured = systemSelections(in: group, query: query)
            if !structured.isEmpty {
                selections = structured
            } else {
                let systemPrefix = group.items.contains { item in
                    ([item.key, item.name] + item.aliases).contains { normalizedLabel($0).hasPrefix(lookup) }
                }
                if !systemPrefix, group.items.contains(where: { bestEnvironmentFilter(token: lookup, environments: $0.environments) != nil }) {
                    selections = group.items.map { SystemSelection(item: $0, remainder: query, score: 500, exact: true, wordCount: 0) }
                } else {
                    selections = group.items.compactMap { item in
                        matchScore(item, query: query).map { SystemSelection(item: item, remainder: "", score: $0, exact: false, wordCount: 0) }
                    }
                }
            }
        }
        return selections.flatMap { selection in
            results(group: group, item: selection.item, query: selection.remainder, score: selection.score)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func systemSelections(in group: WebsiteShortcutGroup, query: String) -> [SystemSelection] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [] }
        var candidates: [SystemSelection] = []
        for item in group.items {
            for count in 1..<words.count {
                for suffix in [false, true] {
                    let system = (suffix ? Array(words.suffix(count)) : Array(words.prefix(count))).joined(separator: " ")
                    let token = normalizedLabel(system)
                    let identifiers = ([item.key] + item.aliases).map(normalizedLabel)
                    let labels = identifiers + [normalizedLabel(item.name)]
                    let exact = labels.contains(token)
                    guard exact || labels.contains(where: { $0.hasPrefix(token) }) else { continue }
                    let remainder = (suffix ? Array(words.dropLast(count)) : Array(words.dropFirst(count))).joined(separator: " ")
                    candidates.append(SystemSelection(item: item, remainder: remainder,
                        score: matchScore(item, query: system) ?? 900, exact: exact, wordCount: count))
                }
            }
        }
        // Bind the system before interpreting selectors, so another system's
        // environment or partially typed alias cannot consume this system's name.
        if candidates.contains(where: \.exact) { candidates.removeAll { !$0.exact } }
        guard let longest = candidates.map(\.wordCount).max() else { return [] }
        candidates.removeAll { $0.wordCount != longest }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.item.key).inserted }
    }

    private struct AddressSelection {
        let pages: [WebsiteShortcutPage?]
        let environment: EnvironmentFilter?
    }

    private func addressSelection(item: WebsiteShortcut, query: String) -> AddressSelection? {
        if query.isEmpty { return AddressSelection(pages: [nil] + item.pages.map { Optional($0) }, environment: nil) }
        let token = normalizedLabel(query)
        if let pages = matchingPages(item.pages, token: token, exact: true) {
            return AddressSelection(pages: pages, environment: nil)
        }
        let words = token.split(separator: " ").map(String.init)
        if words.count > 1 {
            for count in stride(from: words.count - 1, through: 1, by: -1) {
                let pageToken = words.prefix(count).joined(separator: " ")
                let environmentToken = words.dropFirst(count).joined(separator: " ")
                guard let pages = matchingPages(item.pages, token: pageToken, exact: true)
                    ?? matchingPages(item.pages, token: pageToken, exact: false),
                    let environment = bestEnvironmentFilter(token: environmentToken, environments: item.environments) else { continue }
                return AddressSelection(pages: pages, environment: environment)
            }
        }
        let environment = bestEnvironmentFilter(token: token, environments: item.environments)
        if let environment, [.identifierExact, .nameExact].contains(environment.match) {
            return AddressSelection(pages: [nil], environment: environment)
        }
        if let pages = matchingPages(item.pages, token: token, exact: false) {
            return AddressSelection(pages: pages, environment: nil)
        }
        if let environment { return AddressSelection(pages: [nil], environment: environment) }
        return nil
    }

    private func matchingPages(_ pages: [WebsiteShortcutPage], token: String, exact: Bool) -> [WebsiteShortcutPage?]? {
        let homeLabels = ["home", "首页"]
        if homeLabels.contains(where: { exact ? $0 == token : $0.hasPrefix(token) }) { return [nil] }
        for identifiers in [true, false] {
            let matched = pages.filter { page in
                let labels = identifiers ? [page.key] + page.aliases : [page.name]
                return labels.contains { label in
                    let normalized = normalizedLabel(label)
                    return exact ? normalized == token : normalized.hasPrefix(token)
                }
            }
            if !matched.isEmpty { return matched.map { Optional($0) } }
        }
        return nil
    }

    private func results(group: WebsiteShortcutGroup, item: WebsiteShortcut, query: String, score: Double) -> [SearchItem] {
        guard let selection = addressSelection(item: item, query: query) else { return [] }
        let environments: [WebsiteShortcutEnvironment?] = item.environments.isEmpty ? [nil] : item.environments.map { Optional($0) }
        var results: [SearchItem] = []
        for page in selection.pages {
            for environment in environments {
                if let filter = selection.environment {
                    guard let environment, matchesEnvironment(environment, filter: filter) else { continue }
                }
                let baseURL = environment?.url ?? item.url
                let url: String
                if let page {
                    guard let resolved = try? page.resolvedURL(baseURL: baseURL, environmentKey: environment?.key) else { continue }
                    url = resolved.absoluteString
                } else { url = baseURL }
                let homeBonus = query.isEmpty && page == nil && !item.pages.isEmpty ? 1.0 : 0.0
                results.append(result(group: group, item: item, page: page, environment: environment, urlString: url, score: score + homeBonus))
            }
        }
        return results
    }

    private func matchScore(_ item: WebsiteShortcut, query: String) -> Double? {
        if query.isEmpty { return 500 }
        let candidates = [item.key] + item.aliases + [item.name]
        guard let best = candidates.compactMap({ FuzzyMatcher.score(query: query, candidate: $0) }).max() else { return nil }
        let lookup = WebsiteShortcutConfiguration.lookupKey(query)
        if lookup == WebsiteShortcutConfiguration.lookupKey(item.key) { return 3000 }
        if item.aliases.contains(where: { lookup == WebsiteShortcutConfiguration.lookupKey($0) }) { return 2500 }
        return best
    }

    private enum EnvironmentMatch: CaseIterable {
        case identifierExact, nameExact, identifierPrefix, namePrefix
    }

    private struct EnvironmentFilter {
        let token: String
        let match: EnvironmentMatch
    }

    private func normalizedLabel(_ label: String) -> String {
        WebsiteShortcutConfiguration.environmentLookupKey(label)
    }

    private func bestEnvironmentFilter(token: String, environments: [WebsiteShortcutEnvironment]) -> EnvironmentFilter? {
        // Resolve priority inside the selected system, so another system's "prod"
        // cannot hide this system's "production" endpoint.
        for match in EnvironmentMatch.allCases {
            let filter = EnvironmentFilter(token: token, match: match)
            if environments.contains(where: { matchesEnvironment($0, filter: filter) }) { return filter }
        }
        return nil
    }

    private func matchesEnvironment(_ environment: WebsiteShortcutEnvironment, filter: EnvironmentFilter) -> Bool {
        switch filter.match {
        case .identifierExact:
            return ([environment.key] + environment.aliases).contains { normalizedLabel($0) == filter.token }
        case .nameExact:
            return normalizedLabel(environment.name) == filter.token
        case .identifierPrefix:
            return ([environment.key] + environment.aliases).contains { normalizedLabel($0).hasPrefix(filter.token) }
        case .namePrefix:
            return normalizedLabel(environment.name).hasPrefix(filter.token)
        }
    }

    private func environmentLabels(_ environment: WebsiteShortcutEnvironment) -> [String] {
        ([environment.key, environment.name] + environment.aliases).map(normalizedLabel)
    }

    private func result(group: WebsiteShortcutGroup, item: WebsiteShortcut, page: WebsiteShortcutPage?, environment: WebsiteShortcutEnvironment?, urlString: String, score: Double) -> SearchItem {
        let canonicalKey: String
        let subtitle: String
        let badge: SearchItemBadge?
        if let page {
            let parts = [group.keyword, item.key, page.key, environment?.key ?? ""]
            canonicalKey = "website-page:" + parts.map(escapedIdentity).joined(separator: ":")
            subtitle = urlString
            badge = environment.map { SearchItemBadge(text: $0.key.uppercased(), tint: environmentTint($0)) }
        } else if let environment {
            canonicalKey = "website-environment:\(group.keyword):\(escapedIdentity(item.key)):\(escapedIdentity(environment.key))"
            subtitle = urlString
            badge = SearchItemBadge(text: environment.key.uppercased(), tint: environmentTint(environment))
        } else {
            canonicalKey = "website:\(group.keyword):\(item.key)"
            subtitle = item.pages.isEmpty ? "\(group.keyword) \(item.key) · \(urlString)" : urlString
            badge = nil
        }
        let opener = self.opener; let feedback = self.feedback
        let url = URL(string: urlString)
        let title = page.map { "\(item.name) · \($0.name)" } ?? (item.pages.isEmpty ? item.name : "\(item.name) · 首页")
        return SearchItem(providerID: id, group: .shortcut, title: title,
            subtitle: subtitle, icon: .symbol(name: "link", tint: .teal), score: score,
            canonicalKey: canonicalKey, actions: [ItemAction(id: "website.open", title: "打开网址") { [weak self] in
                guard self?.isEnabled == true, !Task.isCancelled, let url else { return }
                do { try opener.open(url) } catch { feedback.show(error.localizedDescription) }
            }], badge: badge)
    }

    private func escapedIdentity(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func environmentTint(_ environment: WebsiteShortcutEnvironment) -> IconTint {
        let labels = Set(environmentLabels(environment))
        if !labels.isDisjoint(with: ["prod", "production", "live", "生产", "正式", "线上"]) { return .red }
        if !labels.isDisjoint(with: ["test", "testing", "qa", "dev", "development", "staging", "uat", "测试", "开发", "预发"]) { return .blue }
        return .gray
    }
}
