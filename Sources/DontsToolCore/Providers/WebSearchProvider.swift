import Foundation

@MainActor
public final class WebSearchProvider: ToolProvider {
    public let id = ProviderID.web.rawValue
    public let displayName = "网页搜索"
    public var keywords: [String] { availableEngines.map(\.keyword) }
    public let priority = 150
    public let phase = SearchPhase.fast
    public var statusNotice: String? { engines.loadError }

    private let settings: SettingsStore
    private let engines: SearchEngineStore
    private let unavailableKeywords: @MainActor () -> Set<String>
    private let usage: UsageStore
    private let opener: URLOpening
    private let feedback: FeedbackProviding
    private let prefill: QueryPrefilling
    private let clipboard: ClipboardProviding

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(settings: SettingsStore, engines: SearchEngineStore, usage: UsageStore,
                opener: URLOpening, feedback: FeedbackProviding, prefill: QueryPrefilling,
                clipboard: ClipboardProviding = SystemClipboard(),
                unavailableKeywords: @escaping @MainActor () -> Set<String> = { [] }) {
        self.settings = settings
        self.engines = engines
        self.usage = usage
        self.opener = opener
        self.feedback = feedback
        self.prefill = prefill
        self.clipboard = clipboard
        self.unavailableKeywords = unavailableKeywords
    }

    private var availableEngines: [SearchEngineDefinition] {
        let unavailable = unavailableKeywords()
        return engines.configuration.enabledEngines.filter { !unavailable.contains($0.keyword) }
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled else { return [] }
        switch context.mode {
        case .keyword(let providerID, let keyword, _) where providerID == id:
            guard let engine = availableEngines.first(where: { $0.keyword == keyword }) else { return [] }
            if context.query.isEmpty { return [entry(for: engine)] }
            return [searchItem(query: context.query, engine: engine)].compactMap { $0 }
        case .global where context.query.isEmpty:
            let configuredDefault = engines.configuration.defaultEngine
            guard let engine = availableEngines.first(where: { $0.id == configuredDefault.id }) ?? availableEngines.first else { return [] }
            return [entry(for: engine, defaultHint: engine.id == configuredDefault.id)]
        case .global:
            let matches = availableEngines.compactMap { engine -> (SearchEngineDefinition, Double)? in
                let score = max(FuzzyMatcher.score(query: context.query, candidate: engine.name) ?? 0,
                                FuzzyMatcher.score(query: context.query, candidate: engine.keyword) ?? 0)
                return score >= 650 ? (engine, score) : nil
            }.sorted { $0.1 > $1.1 }
            return matches.prefix(8).map { entry(for: $0.0) }
                + [searchItem(query: context.query, engine: engines.configuration.defaultEngine)].compactMap { $0 }
        default:
            return []
        }
    }

    private func entry(for engine: SearchEngineDefinition, defaultHint: Bool = false) -> SearchItem {
        let prefill = self.prefill
        let keyword = engine.keyword
        return SearchItem(providerID: id, group: .tool,
            title: defaultHint ? "网页搜索" : "\(engine.name) 搜索",
            subtitle: defaultHint ? "默认引擎：\(engine.name)" : "输入 \(engine.keyword) 搜索内容 · 回车填入快捷词",
            icon: .symbol(name: "globe", tint: .blue), score: defaultHint ? 900 : 950,
            canonicalKey: "web.engine:\(engine.id)",
            actions: [ItemAction(id: "web.prefill", title: "填入快捷词", presentation: .keepPanelOpen) {
                prefill.prefill(keyword + " ")
            }], keyword: keyword)
    }

    private func searchItem(query: String, engine: SearchEngineDefinition) -> SearchItem? {
        guard let url = engine.searchURL(for: query) else { return nil }
        let opener = self.opener
        let feedback = self.feedback
        let usage = self.usage
        let clipboard = self.clipboard
        let canonicalKey = url.absoluteString
        return SearchItem(providerID: id, group: .web,
            title: "用 \(engine.name) 搜索 “\(query)”", subtitle: "\(engine.name) · 回车打开浏览器",
            icon: .symbol(name: "magnifyingglass", tint: .blue), score: 100, canonicalKey: canonicalKey,
            actions: [
                ItemAction(id: "web.open", title: "打开", symbol: "arrow.up.forward.app") {
                    do { try opener.open(url); usage.recordUse(of: canonicalKey) }
                    catch { feedback.show(error.localizedDescription) }
                },
                ItemAction(id: "web.copy", title: "复制链接", symbol: "link") {
                    clipboard.writeString(canonicalKey); feedback.show("已复制链接")
                }
            ])
    }
}
