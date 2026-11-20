import Foundation
import os

@MainActor
public final class GeminiProvider: ToolProvider {
    public static let entryCanonicalKey = "gemini:entry"

    public let id = "gemini"
    public let displayName = "Gemini 提问"
    public let keywords = ["gm", "gemini"]
    public let priority = 200
    public let supportsGlobalSearch = false
    private let index: AppIndex
    private let settings: SettingsStore
    private let service: any GeminiAsking
    private let logger = Logger(subsystem: "com.donts.DontsTool", category: "gemini-handoff")
    private let feedback: any FeedbackProviding
    private let usage: UsageStore?
    private let prefill: (any QueryPrefilling)?

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        index: AppIndex,
        settings: SettingsStore,
        service: any GeminiAsking,
        feedback: any FeedbackProviding,
        usage: UsageStore? = nil,
        prefill: (any QueryPrefilling)? = nil
    ) {
        self.index = index
        self.settings = settings
        self.service = service
        self.feedback = feedback
        self.usage = usage
        self.prefill = prefill
    }

    public func homeToolEntry() -> SearchItem? {
        guard isEnabled,
              let app = index.apps.first(where: { $0.bundleID == GeminiConversationService.applicationBundleIdentifier }) else {
            return nil
        }
        let prefill = self.prefill
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "Gemini 提问",
            subtitle: "输入 gm 加问题，向 Gemini 发起新对话",
            icon: .application(path: app.url.path),
            score: 897,
            canonicalKey: Self.entryCanonicalKey,
            actions: [ItemAction(id: "gemini.enter", title: "进入 Gemini 提问", presentation: .keepPanelOpen, symbol: "sparkles") {
                prefill?.prefill("gm ")
            }],
            keyword: "gm"
        )
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled, case .keyword(let providerID, let keyword, _) = context.mode,
              providerID == id else { return [] }
        guard let app = index.apps.first(where: { $0.bundleID == GeminiConversationService.applicationBundleIdentifier }) else {
            return [hint("未找到 Gemini 应用", detail: "安装 Gemini Mac 版后重新扫描应用")]
        }
        let question = context.query
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [SearchItem(providerID: id, group: .tool, title: "向 Gemini 发起新对话",
                subtitle: "输入 gm 加问题，回车后新建并发送；也可只打开应用", icon: .application(path: app.url.path),
                score: 1500, canonicalKey: "gemini:open", actions: [openAction(app.url)], keyword: keyword)]
        }
        guard question.utf16.count <= GeminiConversationService.maximumQuestionLength else {
            return [hint("问题过长", detail: "请直接在 Gemini 中编辑")]
        }
        let service = service
        let feedback = feedback
        let logger = logger
        let settings = settings
        let usage = usage
        let id = id
        return [SearchItem(providerID: id, group: .tool, title: "向 Gemini 发送新问题",
            subtitle: "新建对话 · \(question.count) 个字符 · 回车才发送", icon: .application(path: app.url.path),
            score: 1800, canonicalKey: "gemini:ask", actions: [
                ItemAction(id: "gemini.ask", title: "新建并发送", symbol: "paperplane") {
                    guard settings.isProviderEnabled(id) else { return }
                    do {
                        try await service.ask(question, in: app.url)
                        usage?.recordUse(of: Self.entryCanonicalKey)
                    } catch {
                        logger.error("Gemini 提问失败：\(error.localizedDescription, privacy: .public)")
                        feedback.show(error.localizedDescription)
                    }
                }, openAction(app.url)
            ], keyword: keyword)]
    }

    private func openAction(_ application: URL) -> ItemAction {
        let service = service
        let feedback = feedback
        let settings = settings
        let usage = usage
        let id = id
        return ItemAction(id: "gemini.open", title: "仅打开 Gemini", symbol: "arrow.up.forward.app") {
            guard settings.isProviderEnabled(id) else { return }
            do {
                try await service.open(in: application)
                usage?.recordUse(of: Self.entryCanonicalKey)
            } catch { feedback.show(error.localizedDescription) }
        }
    }

    private func hint(_ title: String, detail: String) -> SearchItem {
        let feedback = feedback
        return SearchItem(providerID: id, group: .tool, title: title, subtitle: detail,
            icon: .symbol(name: "sparkles", tint: .blue), score: 1200, canonicalKey: "gemini:hint",
            actions: [ItemAction(id: "gemini.hint", title: "查看提示", presentation: .keepPanelOpen) { feedback.show(detail) }])
    }
}
