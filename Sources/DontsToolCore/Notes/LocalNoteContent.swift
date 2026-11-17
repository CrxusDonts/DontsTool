import Foundation

public struct LocalNoteContent: Codable, Equatable, Sendable {
    public var json: String
    public var markdown: String
    public var plainText: String

    public init(json: String, markdown: String, plainText: String) {
        self.json = json
        self.markdown = markdown
        self.plainText = plainText
    }

    public static let empty = LocalNoteContent(json: "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}]}", markdown: "", plainText: "")
}
