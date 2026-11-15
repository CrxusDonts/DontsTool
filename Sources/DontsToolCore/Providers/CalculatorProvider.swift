import Foundation

/// 全局输入算式时直接给出结果；回车复制，不创建工具窗口。
@MainActor
public final class CalculatorProvider: ToolProvider {
    public let id = ProviderID.calculator.rawValue
    public let displayName = "计算器"
    public let keywords = ["calc", "="]
    public let priority = 300
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }

    private let settings: SettingsStore
    private let clipboard: any ClipboardProviding
    private let feedback: any FeedbackProviding

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(settings: SettingsStore, clipboard: any ClipboardProviding, feedback: any FeedbackProviding) {
        self.settings = settings
        self.clipboard = clipboard
        self.feedback = feedback
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled else { return [] }
        switch context.mode {
        case .keyword(let providerID, let keyword, _) where providerID == id:
            return keywordItems(keyword: keyword, argument: context.query)
        case .global:
            guard let calculation = CalculatorEngine.calculate(context.query) else { return [] }
            return [resultItem(calculation, expression: context.query, keyword: nil)]
        default:
            return []
        }
    }

    private func keywordItems(keyword: String, argument: String) -> [SearchItem] {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [hintItem(
                title: "计算器",
                subtitle: "输入算式或单位换算，如 12 km to mi",
                canonicalKey: "calc:hint"
            )]
        }
        guard let calculation = CalculatorEngine.calculate(trimmed) else {
            return [hintItem(
                title: "无法计算这个表达式",
                subtitle: "支持 + - * / ^ %、括号、sqrt 等函数与单位换算",
                canonicalKey: "calc:invalid"
            )]
        }
        return [resultItem(calculation, expression: trimmed, keyword: keyword)]
    }

    private func resultItem(_ calculation: Calculation, expression: String, keyword: String?) -> SearchItem {
        let clipboard = self.clipboard
        let feedback = self.feedback
        return SearchItem(
            providerID: id,
            group: .tool,
            title: calculation.text,
            subtitle: "\(expression) · 回车复制结果",
            icon: .symbol(name: "plus.forwardslash.minus", tint: .amber),
            score: 3000,
            canonicalKey: "calc:\(expression.lowercased())",
            actions: [
                ItemAction(id: "calc.copy", title: "复制结果", symbol: "doc.on.doc") {
                    clipboard.writeString(calculation.text)
                    feedback.show("已复制 \(calculation.text)")
                }
            ],
            keyword: keyword
        )
    }

    private func hintItem(title: String, subtitle: String, canonicalKey: String) -> SearchItem {
        let feedback = self.feedback
        return SearchItem(
            providerID: id,
            group: .tool,
            title: title,
            subtitle: subtitle,
            icon: .symbol(name: "plus.forwardslash.minus", tint: .amber),
            score: 1200,
            canonicalKey: canonicalKey,
            actions: [
                ItemAction(id: "calc.hint", title: "提示", presentation: .keepPanelOpen, symbol: "info.circle") {
                    feedback.show("请输入算式或单位换算，例如 12 km to mi")
                }
            ],
            keyword: "calc"
        )
    }
}
