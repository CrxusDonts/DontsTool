import Foundation

@MainActor
public final class WebSearchProvider: ToolProvider {
    public let id = ProviderID.web.rawValue
    public let displayName = "网页搜索"
    public let keywords = ["g", "bing", "bd", "ddg", "gh"]
    public let priority = 150
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }

    private enum Target {
        case engine(SettingsStore.SearchEngine, keyword: String)
        case github
    }

    private let settings: SettingsStore
    private let usage: UsageStore
    private let opener: URLOpening
    private let feedback: FeedbackProviding
    private let prefill: QueryPrefilling

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        settings: SettingsStore,
        usage: UsageStore,
        opener: URLOpening,
        feedback: FeedbackProviding,
        prefill: QueryPrefilling
    ) {
        self.settings = settings
        self.usage = usage
        self.opener = opener
        self.feedback = feedback
        self.prefill = prefill
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled else { return [] }

        switch context.mode {
        case .keyword(let providerID, let keyword, _) where providerID == id:
            return [keywordItem(keyword: keyword, argument: context.query)]
        case .global where context.query.isEmpty:
            return [hintItem()]
        case .global:
            return [fallbackItem(query: context.query)]
        default:
            return []
        }
    }

    private func target(for keyword: String) -> Target? {
        switch keyword {
        case "g": .engine(.google, keyword: keyword)
        case "bing": .engine(.bing, keyword: keyword)
        case "bd": .engine(.baidu, keyword: keyword)
        case "ddg": .engine(.ddg, keyword: keyword)
        case "gh": .github
        default: nil
        }
    }

    private func keywordItem(keyword: String, argument: String) -> SearchItem {
        guard let target = target(for: keyword) else {
            return hintItem()
        }
        guard !argument.isEmpty else {
            let feedback = self.feedback
            return SearchItem(
                providerID: id,
                group: .tool,
                title: "输入要搜索的内容",
                subtitle: displayName(for: target),
                icon: .symbol(name: "magnifyingglass", tint: .blue),
                score: 1000,
                canonicalKey: "web.empty:\(keyword)",
                actions: [
                    ItemAction(id: "web.empty", title: "提示", presentation: .keepPanelOpen) {
                        feedback.show("请输入要搜索的内容")
                    }
                ]
            )
        }
        return makeWebItem(query: argument, target: target)
    }

    private func fallbackItem(query: String) -> SearchItem {
        makeWebItem(query: query, target: .engine(settings.defaultSearchEngine, keyword: "fallback"))
    }

    private func hintItem() -> SearchItem {
        let prefill = self.prefill
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "网页搜索",
            subtitle: "默认引擎：\(settings.defaultSearchEngine.displayName)",
            icon: .symbol(name: "globe", tint: .blue),
            score: 900,
            canonicalKey: "hint:web",
            actions: [
                ItemAction(id: "web.prefill", title: "填入关键词", presentation: .keepPanelOpen) {
                    prefill.prefill("g ")
                }
            ],
            keyword: "g"
        )
    }

    private func makeWebItem(query: String, target: Target) -> SearchItem {
        let url: URL
        let title: String
        let targetName: String
        switch target {
        case .engine(let engine, _):
            guard let built = engine.searchURL(for: query) else {
                preconditionFailure("搜索引擎 URL 构造失败")
            }
            url = built
            targetName = engine.displayName
            title = "用 \(engine.displayName) 搜索 “\(query)”"
        case .github:
            var components = URLComponents()
            components.scheme = "https"
            components.host = "github.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let built = components.url else {
                preconditionFailure("GitHub URL 构造失败")
            }
            url = built
            targetName = "GitHub"
            title = "在 GitHub 搜索 “\(query)”"
        }

        let opener = self.opener
        let feedback = self.feedback
        let usage = self.usage
        let canonicalKey = url.absoluteString

        return SearchItem(
            providerID: id,
            group: .web,
            title: title,
            subtitle: "\(targetName) · 回车打开浏览器",
            icon: .symbol(name: "magnifyingglass", tint: .blue),
            score: 100,
            canonicalKey: canonicalKey,
            actions: [
                ItemAction(id: "web.open", title: "打开") {
                    do {
                        try opener.open(url)
                        usage.recordUse(of: canonicalKey)
                    } catch {
                        feedback.show(error.localizedDescription)
                    }
                }
            ]
        )
    }

    private func displayName(for target: Target) -> String {
        switch target {
        case .engine(let engine, _): engine.displayName
        case .github: "GitHub"
        }
    }
}
