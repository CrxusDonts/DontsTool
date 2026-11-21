import Foundation

/// Recommends actions for content explicitly supplied by the user.
@MainActor
public final class ContentActionProvider {
    private let settings: SettingsStore
    private let toolOpener: ToolOpening
    private let urlOpener: URLOpening
    private let feedback: FeedbackProviding
    private let noteOpener: (any LocalNoteOpening)?
    private let openAI: (@MainActor (QuickAIRequest) -> Void)?

    public init(
        settings: SettingsStore,
        toolOpener: ToolOpening,
        urlOpener: URLOpening,
        feedback: FeedbackProviding,
        noteOpener: (any LocalNoteOpening)? = nil,
        openAI: (@MainActor (QuickAIRequest) -> Void)? = nil
    ) {
        self.settings = settings
        self.toolOpener = toolOpener
        self.urlOpener = urlOpener
        self.feedback = feedback
        self.noteOpener = noteOpener
        self.openAI = openAI
    }

    public func items(for text: String, matching query: String = "") -> [SearchItem] {
        guard let descriptor = ContentDescriptor(text: text) else { return [] }
        var candidates: [(SearchItem, [String])] = []
        switch descriptor.kind {
        case .json:
            appendTool(.json, mode: "format", title: "打开 JSON 工具", keyword: "json", input: text, into: &candidates)
        case .url:
            if settings.isProviderEnabled(ProviderID.web.rawValue), let url = ContentDescriptor.webURL(in: text) {
                let key = "content:url.open"
                let item = SearchItem(
                    id: key, providerID: "content", group: .tool, title: "在默认浏览器打开",
                    subtitle: "打开这条网页链接", icon: .symbol(name: "globe", tint: .blue),
                    score: 1000, canonicalKey: key,
                    actions: [ItemAction(id: key, title: "打开链接") { [settings, urlOpener, feedback] in
                        guard settings.isProviderEnabled(ProviderID.web.rawValue) else {
                            feedback.show("网页搜索已停用，请先在设置中启用")
                            return
                        }
                        try urlOpener.open(url)
                    }]
                )
                candidates.append((item, ["browser", "open", "浏览器", "链接"]))
            }
            appendTool(.url, mode: "encode", title: "打开 URL 编码", keyword: "url", input: text, into: &candidates)
            appendTool(.url, mode: "decode", title: "打开 URL 解码", keyword: "urld", input: text, into: &candidates)
        case .text:
            appendTool(.base64, mode: "encode", title: "打开 Base64 编码", keyword: "b64", input: text, into: &candidates)
            appendTool(.base64, mode: "decode", title: "打开 Base64 解码", keyword: "b64d", input: text, into: &candidates)
            appendTool(.translation, mode: "translation", title: "打开翻译", keyword: "tr", input: text, into: &candidates)
        }
        appendNoteActions(for: text, into: &candidates)
        appendAIAction(for: text, into: &candidates)
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return candidates.filter { item, aliases in
            normalized.isEmpty || ([item.title, item.keyword ?? ""] + aliases).contains {
                $0.lowercased().contains(normalized)
            }
        }.map(\.0)
    }

    private func appendNoteActions(for text: String, into candidates: inout [(SearchItem, [String])]) {
        guard let noteOpener, settings.isProviderEnabled(ProviderID.notes.rawValue) else { return }
        let dailyTitle = LocalNoteStore.dailyNoteTitle()
        let captureKey = "content:notes.capture"
        let captureItem = SearchItem(
            id: captureKey,
            providerID: "content",
            group: .tool,
            title: "追加到今日速记",
            subtitle: "直接写入「\(dailyTitle)」，不打断当前窗口",
            icon: .symbol(name: "text.append", tint: .amber),
            score: 990 - Double(candidates.count),
            canonicalKey: captureKey,
            actions: [ItemAction(id: captureKey, title: "追加速记", symbol: "text.append") { [settings, noteOpener, feedback] in
                guard settings.isProviderEnabled(ProviderID.notes.rawValue) else {
                    feedback.show("便笺已停用，请先在设置中启用")
                    return
                }
                let record = try noteOpener.quickCapture(text)
                feedback.show("已记入「\(record.title)」")
            }],
            keyword: "note"
        )
        candidates.append((captureItem, ["note", "notes", "便笺", "笔记", "速记", "capture"]))

        let createKey = "content:notes.create"
        let createItem = SearchItem(
            id: createKey,
            providerID: "content",
            group: .tool,
            title: "存为新便笺",
            subtitle: "带入原文并打开便笺窗口",
            icon: .symbol(name: "note.text.badge.plus", tint: .amber),
            score: 990 - Double(candidates.count),
            canonicalKey: createKey,
            actions: [ItemAction(id: createKey, title: "存为便笺", presentation: .openWindow, symbol: "note.text.badge.plus") { [settings, noteOpener, feedback] in
                guard settings.isProviderEnabled(ProviderID.notes.rawValue) else {
                    feedback.show("便笺已停用，请先在设置中启用")
                    return
                }
                noteOpener.createNote(with: text)
            }],
            keyword: "note"
        )
        candidates.append((createItem, ["note", "notes", "便笺", "笔记", "新建"]))
    }

    private func appendAIAction(for text: String, into candidates: inout [(SearchItem, [String])]) {
        guard let openAI else { return }
        let key = "content:ai.ask"
        let item = SearchItem(
            id: key,
            providerID: "content",
            group: .tool,
            title: "问 AI（预填到 AI 窗口）",
            subtitle: "带入原文到 AI 窗口，由你确认后再发送",
            icon: .symbol(name: "sparkles", tint: .blue),
            score: 990 - Double(candidates.count),
            canonicalKey: key,
            actions: [
                ItemAction(id: key, title: "在 AI 窗口中提问", presentation: .openWindow, symbol: "sparkles") {
                    openAI(QuickAIRequest(title: "AI 快问", prompt: text, systemPrompt: nil, autoSend: false))
                }
            ],
            keyword: "ai"
        )
        candidates.append((item, ["ai", "ask", "chat", "问", "提问", "大模型"]))
    }

    private func appendTool(
        _ kind: ToolKind, mode: String, title: String, keyword: String, input: String,
        into candidates: inout [(SearchItem, [String])]
    ) {
        let providerID = kind == .translation ? ProviderID.translation.rawValue : ProviderID.text.rawValue
        guard settings.isProviderEnabled(providerID) else { return }
        let suffix = kind == .json || kind == .translation ? kind.rawValue : "\(kind.rawValue).\(mode)"
        let key = "content:\(suffix)"
        let item = SearchItem(
            id: key, providerID: "content", group: .tool, title: title,
            subtitle: kind == .translation ? "带入原文，在独立窗口中发起翻译" : "带入原文，在独立窗口中编辑和处理",
            icon: kind.icon, score: 990 - Double(candidates.count), canonicalKey: key,
            actions: [ItemAction(id: key, title: "打开工具窗口", presentation: .openWindow) { [settings, toolOpener, feedback] in
                guard settings.isProviderEnabled(providerID) else {
                    feedback.show("\(kind == .translation ? "翻译" : "文本工具")已停用，请先在设置中启用")
                    return
                }
                toolOpener.openTool(ToolOpenRequest(kind: kind, mode: mode, input: input))
            }], keyword: keyword
        )
        let aliases = kind == .translation ? ["translate", "translation"] : [kind.rawValue, mode]
        candidates.append((item, aliases))
    }
}
