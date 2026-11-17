import Foundation

public struct LocalNoteRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public let id: UUID
    public var title: String
    public var titleIsAutomatic: Bool
    public var isPinned: Bool
    public let createdAt: Date
    public var updatedAt: Date
    public var content: LocalNoteContent

    public init(id: UUID = UUID(), title: String = "未命名便笺", titleIsAutomatic: Bool = true, isPinned: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date(), content: LocalNoteContent = .empty) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.title = title
        self.titleIsAutomatic = titleIsAutomatic
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.content = content
    }
}
