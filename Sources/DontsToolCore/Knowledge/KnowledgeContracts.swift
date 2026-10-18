import Foundation

public enum KnowledgeSurface: String, CaseIterable, Sendable {
    case search
    case editor
    case inbox
    case capture
}

public struct KnowledgeOpenRequest: Equatable, Sendable {
    public let surface: KnowledgeSurface
    public let documentID: String?
    /// Search query, or capture draft text delivered through the authenticated bridge.
    public let query: String?
    public let blockID: String?

    public init(surface: KnowledgeSurface, documentID: String? = nil, query: String? = nil, blockID: String? = nil) {
        self.surface = surface
        self.documentID = documentID
        self.query = query
        self.blockID = blockID
    }
}

public struct KnowledgeSearchResult: Equatable, Sendable {
    public let id: String
    public let title: String
    public let excerpt: String?

    public init(id: String, title: String, excerpt: String? = nil) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
    }
}

@MainActor
public protocol KnowledgeServing: AnyObject {
    func openKnowledge(_ request: KnowledgeOpenRequest)
    func searchKnowledge(_ query: String) async throws -> [KnowledgeSearchResult]
    var statusNotice: String? { get }
}
