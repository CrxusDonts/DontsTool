import Foundation

@MainActor
public final class NotesProvider: ToolProvider {
    public let id = ProviderID.notes.rawValue
    public let displayName = "便笺"
    public let priority = 200
    public var keywords: [String] {
        let unavailable = Set(unavailableKeywords().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return ["note", "便笺"].filter { !unavailable.contains($0) }
    }
    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }
    public var statusNotice: String? { store.loadError }

    private let settings: SettingsStore
    private let store: LocalNoteStore
    private let opener: any LocalNoteOpening
    private let unavailableKeywords: @MainActor () -> Set<String>

    public init(settings: SettingsStore, store: LocalNoteStore, opener: any LocalNoteOpening,
                unavailableKeywords: @escaping @MainActor () -> Set<String> = { [] }) {
        self.settings = settings
        self.store = store
        self.opener = opener
        self.unavailableKeywords = unavailableKeywords
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled, !Task.isCancelled else { return [] }
        switch context.mode {
        case .global:
            let query = context.query
            let aliases = ["便笺", "笔记", "note", "notes"]
            guard query.isEmpty || aliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) else { return [] }
            return [newNoteEntry(scoped: false)]
        case .keyword(let providerID, let keyword, _) where providerID == id:
            guard keywords.contains(keyword.lowercased()) else { return [] }
            return [newNoteEntry(scoped: true)] + store.search(context.query, limit: 30).enumerated().map { index, note in
                noteEntry(note, score: 1500 - Double(index))
            }
        default:
            return []
        }
    }

    private func newNoteEntry(scoped: Bool) -> SearchItem {
        let settings = settings
        let opener = opener
        let id = id
        let keyword = keywords.first
        return SearchItem(providerID: id, group: .tool, title: scoped ? "新建便笺" : "便笺",
            subtitle: scoped ? "记录文字、代码和图片，自动保存在本机" : (keyword.map { "输入 \($0) 查看最近便笺和搜索正文 · 回车新建" } ?? "记录文字、代码和图片 · 回车新建便笺"),
            icon: .symbol(name: "note.text", tint: .amber), score: 2000, canonicalKey: "notes:create",
            actions: [ItemAction(id: "notes.create", title: "新建便笺", presentation: .openWindow) {
                guard settings.isProviderEnabled(id), !Task.isCancelled else { return }
                opener.createNote()
            }], keyword: keyword)
    }

    private func noteEntry(_ note: LocalNoteRecord, score: Double) -> SearchItem {
        let settings = settings
        let opener = opener
        let store = store
        let id = id
        let summary = note.content.plainText.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? "空白便笺"
        return SearchItem(providerID: id, group: .tool, title: note.title, subtitle: summary,
            icon: .symbol(name: "note.text", tint: .amber), score: score, canonicalKey: "notes:\(note.id.uuidString)",
            actions: [ItemAction(id: "notes.open", title: "打开便笺", presentation: .openWindow) {
                guard settings.isProviderEnabled(id), store.note(note.id) != nil, !Task.isCancelled else { return }
                opener.openNote(note.id)
            }], badge: note.isPinned ? SearchItemBadge(text: "置顶", tint: .amber) : nil)
    }
}
