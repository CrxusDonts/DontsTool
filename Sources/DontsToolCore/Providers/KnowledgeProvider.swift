import Foundation

@MainActor
public final class KnowledgeProvider: ToolProvider {
    public let id = ProviderID.knowledge.rawValue
    public let displayName = "知识库"
    public let keywords = ["kb", "collect", "inbox"]
    public let priority = 150
    // Only scoped kb queries call the service; global entries are always local.
    public let phase = SearchPhase.fast
    public private(set) var statusNotice: String?

    private let settings: SettingsStore
    private let service: any KnowledgeServing

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(settings: SettingsStore, service: any KnowledgeServing) {
        self.settings = settings
        self.service = service
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        statusNotice = nil
        guard isEnabled else { return [] }
        switch context.mode {
        case .keyword(let providerID, let keyword, _) where providerID == id:
            switch keyword {
            case "collect": return [entry(.capture, query: context.query.isEmpty ? nil : context.query)]
            case "inbox": return [entry(.inbox)]
            case "kb": return await knowledgeSearch(context.query)
            default: return []
            }
        case .global:
            let query = context.query.lowercased()
            if query.isEmpty { return [entry(.search), entry(.capture), entry(.inbox)] }
            return [KnowledgeSurface.search, .capture, .inbox].filter { surface in
                switch surface {
                case .search: return ["kb", "knowledge", "知识库"].contains { $0.contains(query) }
                case .capture: return ["collect", "capture", "快速收集"].contains { $0.contains(query) }
                case .inbox: return ["inbox", "收集箱"].contains { $0.contains(query) }
                case .editor: return false
                }
            }.map { entry($0) }
        default: return []
        }
    }

    private func knowledgeSearch(_ query: String) async -> [SearchItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [entry(.search)] }
        guard (try? KnowledgeOrigin(settings.knowledgeBaseURL)) != nil else { return [entry(.search, query: query)] }
        do {
            let results = try await service.searchKnowledge(query)
            guard !Task.isCancelled else { return [] }
            statusNotice = service.statusNotice
            var seen = Set<String>()
            let valid = results.filter { !$0.id.isEmpty && !$0.title.isEmpty && seen.insert($0.id).inserted }
            guard !valid.isEmpty else { return [entry(.search, query: query)] }
            return valid.prefix(8).enumerated().map { index, result in
                let service = self.service
                return SearchItem(
                    providerID: id, group: .knowledge, title: result.title, subtitle: result.excerpt,
                    icon: .symbol(name: "doc.text", tint: .indigo), score: Double(1000 - index),
                    canonicalKey: "knowledge:document:\(result.id)",
                    actions: [ItemAction(id: "knowledge.document.open", title: "打开文档", presentation: .openWindow) {
                        service.openKnowledge(.init(surface: .editor, documentID: result.id))
                    }]
                )
            }
        } catch {
            guard !Task.isCancelled else { return [] }
            statusNotice = service.statusNotice
            return [entry(.search, query: query)]
        }
    }

    private func entry(_ surface: KnowledgeSurface, query: String? = nil) -> SearchItem {
        let title: String
        let subtitle: String
        let keyword: String
        let symbol: String
        switch surface {
        case .search, .editor:
            title = "知识库"
            subtitle = query.map { "在知识库中搜索 “\($0)”" } ?? "搜索和编辑 DontsKb 文档"
            keyword = "kb"
            symbol = "books.vertical"
        case .capture:
            title = "快速收集"
            subtitle = "确认后保存到 DontsKb 收集箱"
            keyword = "collect"
            symbol = "square.and.pencil"
        case .inbox:
            title = "收集箱"
            subtitle = "查看和整理 DontsKb 收集内容"
            keyword = "inbox"
            symbol = "tray"
        }
        let service = self.service
        return SearchItem(
            providerID: id, group: .knowledge, title: title, subtitle: subtitle,
            icon: .symbol(name: symbol, tint: .indigo), score: 900,
            canonicalKey: "knowledge:entry:\(surface.rawValue)",
            actions: [ItemAction(id: "knowledge.\(surface.rawValue).open", title: "打开", presentation: .openWindow) {
                service.openKnowledge(.init(surface: surface, query: query))
            }], keyword: keyword
        )
    }
}
