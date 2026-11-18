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
    private let clipboard: (any ClipboardProviding)?
    private let feedback: (any FeedbackProviding)?
    private let unavailableKeywords: @MainActor () -> Set<String>

    public init(
        settings: SettingsStore,
        store: LocalNoteStore,
        opener: any LocalNoteOpening,
        clipboard: (any ClipboardProviding)? = nil,
        feedback: (any FeedbackProviding)? = nil,
        unavailableKeywords: @escaping @MainActor () -> Set<String> = { [] }
    ) {
        self.settings = settings
        self.store = store
        self.opener = opener
        self.clipboard = clipboard
        self.feedback = feedback
        self.unavailableKeywords = unavailableKeywords
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled, !Task.isCancelled else { return [] }
        switch context.mode {
        case .global:
            let query = context.query
            let aliases = ["便笺", "笔记", "速记", "note", "notes"]
            guard query.isEmpty || aliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) else { return [] }
            return [newNoteEntry(scoped: false)]
        case .keyword(let providerID, let keyword, _) where providerID == id:
            guard keywords.contains(keyword.lowercased()) else { return [] }
            let trimmed = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let recent = store.search("", limit: 30).enumerated().map { index, note in
                    noteEntry(note, score: 1500 - Double(index))
                }
                return [newNoteEntry(scoped: true)] + recent
            }
            let matches = store.search(trimmed, limit: 30).enumerated().map { index, note in
                noteEntry(note, score: 1500 - Double(index))
            }
            if matches.isEmpty {
                return [
                    quickCaptureEntry(text: trimmed, score: 2000),
                    newNoteWithTextEntry(text: trimmed, score: 1990)
                ]
            }
            return matches + [
                quickCaptureEntry(text: trimmed, score: 1400),
                newNoteWithTextEntry(text: trimmed, score: 1390)
            ]
        default:
            return []
        }
    }

    private func newNoteEntry(scoped: Bool) -> SearchItem {
        let settings = settings
        let opener = opener
        let id = id
        let keyword = keywords.first
        return SearchItem(
            providerID: id,
            group: .tool,
            title: scoped ? "新建空白便笺" : "便笺",
            subtitle: scoped ? "打开工作台记录文字、代码和图片" : (keyword.map { "输入 \($0) 搜索、速记或查看最近便笺 · 回车新建" } ?? "记录文字、代码和图片 · 回车新建便笺"),
            icon: .symbol(name: "note.text", tint: .amber),
            score: 2000,
            canonicalKey: "notes:create",
            actions: [ItemAction(id: "notes.create", title: "新建便笺", presentation: .openWindow, symbol: "square.and.pencil") {
                guard settings.isProviderEnabled(id), !Task.isCancelled else { return }
                opener.createNote()
            }],
            keyword: keyword
        )
    }

    private func quickCaptureEntry(text: String, score: Double) -> SearchItem {
        let settings = settings
        let opener = opener
        let feedback = feedback
        let id = id
        let preview = singleLinePreview(text, limit: 48)
        let dailyTitle = LocalNoteStore.dailyNoteTitle()
        let captureAction = ItemAction(id: "notes.quickCapture", title: "记入今日速记", presentation: .dismissThenRun, symbol: "text.append") {
            guard settings.isProviderEnabled(id), !Task.isCancelled else { return }
            let record = try opener.quickCapture(text)
            feedback?.show("已记入「\(record.title)」")
        }
        let openAction = ItemAction(id: "notes.createWithText", title: "新建独立便笺", presentation: .openWindow, symbol: "note.text.badge.plus") {
            guard settings.isProviderEnabled(id), !Task.isCancelled else { return }
            opener.createNote(with: text)
        }
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "速记：“\(preview)”",
            subtitle: "追加到「\(dailyTitle)」（⌘↵ 新建独立便笺）",
            icon: .symbol(name: "text.append", tint: .amber),
            score: score,
            canonicalKey: "notes:quick-capture",
            actions: [captureAction, openAction]
        )
    }

    private func newNoteWithTextEntry(text: String, score: Double) -> SearchItem {
        let settings = settings
        let opener = opener
        let id = id
        let preview = singleLinePreview(text, limit: 48)
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "新建便笺：“\(preview)”",
            subtitle: "创建独立便笺并打开编辑",
            icon: .symbol(name: "note.text.badge.plus", tint: .amber),
            score: score,
            canonicalKey: "notes:create-with-text",
            actions: [ItemAction(id: "notes.createWithText", title: "新建并打开", presentation: .openWindow, symbol: "note.text.badge.plus") {
                guard settings.isProviderEnabled(id), !Task.isCancelled else { return }
                opener.createNote(with: text)
            }]
        )
    }

    private func noteEntry(_ note: LocalNoteRecord, score: Double) -> SearchItem {
        let settings = settings
        let opener = opener
        let store = store
        let clipboard = clipboard
        let feedback = feedback
        let id = id
        let summary = note.content.plainText.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? "空白便笺"
        let timeLabel = Self.relativeTime(for: note.updatedAt)

        var actions: [ItemAction] = [
            ItemAction(id: "notes.open", title: "打开便笺", presentation: .openWindow, symbol: "note.text") {
                guard settings.isProviderEnabled(id), store.note(note.id) != nil, !Task.isCancelled else { return }
                opener.openNote(note.id)
            }
        ]
        if let clipboard {
            actions.append(ItemAction(id: "notes.copyPlain", title: "复制纯文本", presentation: .dismissThenRun, symbol: "doc.on.doc") {
                guard settings.isProviderEnabled(id), let current = store.note(note.id), !Task.isCancelled else { return }
                clipboard.writeString(current.content.plainText)
                feedback?.show("已复制便笺正文")
            })
            actions.append(ItemAction(id: "notes.copyMarkdown", title: "复制 Markdown", presentation: .dismissThenRun, symbol: "number") {
                guard settings.isProviderEnabled(id), let current = store.note(note.id), !Task.isCancelled else { return }
                clipboard.writeString(current.content.markdown)
                feedback?.show("已复制 Markdown")
            })
        }
        actions.append(ItemAction(
            id: "notes.pin",
            title: note.isPinned ? "取消列表置顶" : "列表置顶",
            presentation: .keepPanelOpen,
            symbol: note.isPinned ? "pin.slash" : "pin"
        ) {
            guard settings.isProviderEnabled(id), let current = store.note(note.id), !Task.isCancelled else { return }
            let nextPinned = !current.isPinned
            _ = try store.setPinned(note.id, pinned: nextPinned)
            feedback?.show(nextPinned ? "已在列表置顶" : "已取消列表置顶")
        })
        actions.append(ItemAction(
            id: "notes.trash",
            title: "移入最近删除",
            presentation: .keepPanelOpen,
            symbol: "trash"
        ) {
            guard settings.isProviderEnabled(id), store.note(note.id) != nil, !Task.isCancelled else { return }
            try store.trash(note.id)
            feedback?.show("已移入最近删除")
        })

        return SearchItem(
            providerID: id,
            group: .tool,
            title: note.title,
            subtitle: "\(timeLabel) · \(summary)",
            icon: .symbol(name: "note.text", tint: .amber),
            score: score,
            canonicalKey: "notes:\(note.id.uuidString)",
            actions: actions,
            badge: note.isPinned ? SearchItemBadge(text: "置顶", tint: .amber) : nil
        )
    }

    private func singleLinePreview(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    static func relativeTime(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) 小时前" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let components = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", components.month ?? 1, components.day ?? 1)
    }
}
