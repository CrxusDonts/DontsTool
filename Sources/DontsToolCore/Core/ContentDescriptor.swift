import Foundation

/// Describes deliberately supplied content without retaining the source text.
public struct ContentDescriptor: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case json
        case url
        case text
    }

    public let kind: Kind
    public let displayTitle: String
    public let summary: String

    public init?(text: String) {
        guard text.utf8.count <= ToolOperations.textByteLimit else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if (trimmed.first == "{" || trimmed.first == "["),
           (try? JSONDocument.parse(trimmed)) != nil {
            kind = .json
            displayTitle = "JSON 内容"
        } else if Self.webURL(in: trimmed) != nil {
            kind = .url
            displayTitle = "网页链接"
        } else {
            kind = .text
            displayTitle = "文本内容"
        }
        summary = "\(text.count) 个字符"
    }

    static func webURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
