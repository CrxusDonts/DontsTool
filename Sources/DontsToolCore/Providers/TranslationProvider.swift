import Foundation

@MainActor
public final class TranslationProvider: ToolProvider {
    public let id = ProviderID.translation.rawValue
    public let displayName = "翻译"
    public let keywords = ToolKind.translation.keywords
    public let priority = 150
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
            return [ToolKind.translation.entry(providerID: id, keyword: keyword, input: context.query.isEmpty ? nil : context.query, opener: toolOpener)]
        case .global:
            let entry = context.query.isEmpty || ToolKind.translation.matches(context.query) ? [ToolKind.translation.entry(providerID: id, opener: toolOpener)] : []
            return ToolDocumentDiscovery.items(query: context.query, translation: true, opener: toolOpener) + entry
        default: return []
        }
    }
}
