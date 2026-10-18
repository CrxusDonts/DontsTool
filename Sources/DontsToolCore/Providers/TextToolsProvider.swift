import Foundation

@MainActor
public final class TextToolsProvider: ToolProvider {
    public let id = ProviderID.text.rawValue
    public let displayName = "文本工具"
    public let keywords = ToolKind.allCases.filter { $0 != .translation }.flatMap(\.keywords)
    public let priority = 200
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }
    private let settings: SettingsStore
    private let toolOpener: ToolOpening
    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }
    public init(settings: SettingsStore, toolOpener: ToolOpening) { self.settings = settings; self.toolOpener = toolOpener }
    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled else { return [] }
        switch context.mode {
        case .keyword(let providerID, let keyword, _) where providerID == id:
            guard let tool = ToolKind.forKeyword(keyword), tool != .translation else { return [] }
            return [tool.entry(providerID: id, keyword: keyword, input: context.query.isEmpty ? nil : context.query, opener: toolOpener)]
        case .global:
            return ToolDocumentDiscovery.items(query: context.query, translation: false, opener: toolOpener) + ToolKind.allCases.filter { $0 != .translation && (context.query.isEmpty || $0.matches(context.query)) }.map { $0.entry(providerID: id, opener: toolOpener) }
        default: return []
        }
    }
}
