import Foundation

@MainActor public protocol ToolDocumentProviding: ToolOpening {
    var toolDocuments: [ToolDocument] { get }
    func activateDocument(_ id: UUID)
}
@MainActor public enum ToolDocumentDiscovery {
    public static func items(query: String, translation: Bool, opener: ToolOpening) -> [SearchItem] {
        guard !query.isEmpty, let source = opener as? ToolDocumentProviding else { return [] }
        return source.toolDocuments.filter { document in
            (document.kind == .translation) == translation && (query.isEmpty || document.title.localizedCaseInsensitiveContains(query))
        }.prefix(12).map { document in
            // Keep fresh tool entries ahead of existing windows within the shared tool result cap.
            SearchItem(providerID: translation ? "translation" : "text", group: .tool, title: document.title,
                subtitle: "已打开窗口 · \(document.kind.title)", icon: document.kind.icon, score: 900,
                canonicalKey: "window:\(document.id.uuidString)", actions: [
                    ItemAction(id: "window.activate", title: "切换到窗口", presentation: .openWindow) { source.activateDocument(document.id) }
                ])
        }
    }
}
