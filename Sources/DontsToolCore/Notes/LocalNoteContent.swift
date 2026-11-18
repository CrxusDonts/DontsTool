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

    public static let empty = LocalNoteContent(
        json: "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}]}",
        markdown: "",
        plainText: ""
    )

    /// 从纯文本生成可无损载入 ProseMirror/Tiptap 的文档内容。
    public static func plainText(_ text: String) -> LocalNoteContent {
        let normalized = normalizeLineEndings(text)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let blocks = lines.map(paragraphBlock(for:))
        guard let encoded = encodeDocument(blocks: blocks) else { return .empty }
        return LocalNoteContent(
            json: encoded,
            markdown: lines.joined(separator: "\n\n"),
            plainText: normalized
        )
    }

    /// 在现有便笺末尾追加一条带可选时间戳的记录，保留已有富文本节点与图片。
    public func appending(entry text: String, timestamp: String? = nil) -> LocalNoteContent {
        let normalized = Self.normalizeLineEndings(text)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }

        let existingRoot = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        var blocks = (existingRoot?["content"] as? [[String: Any]]) ?? []
        let hasMeaningfulText = !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMedia = json.contains("\"image\"")
        let hasExistingContent = hasMeaningfulText || hasMedia
        if !hasExistingContent {
            blocks = []
        }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let entryPlain: String
        let entryMarkdown: String
        if lines.count == 1 {
            let line = timestamp.map { "[\($0)] \(lines[0])" } ?? lines[0]
            blocks.append(Self.paragraphBlock(for: line))
            entryPlain = line
            entryMarkdown = line
        } else {
            if let timestamp {
                blocks.append(Self.paragraphBlock(for: "[\(timestamp)]"))
            }
            blocks.append(contentsOf: lines.map(Self.paragraphBlock(for:)))
            entryPlain = timestamp.map { "[\($0)]\n\(trimmed)" } ?? trimmed
            entryMarkdown = (timestamp.map { "[\($0)]\n\n" } ?? "") + lines.joined(separator: "\n\n")
        }

        guard let encoded = Self.encodeDocument(blocks: blocks) else { return self }
        let nextPlain = hasMeaningfulText ? "\(plainText)\n\n\(entryPlain)" : entryPlain
        let existingMarkdownTrimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextMarkdown = existingMarkdownTrimmed.isEmpty ? entryMarkdown : "\(markdown)\n\n\(entryMarkdown)"
        return LocalNoteContent(json: encoded, markdown: nextMarkdown, plainText: nextPlain)
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func paragraphBlock(for line: String) -> [String: Any] {
        if line.isEmpty {
            return ["type": "paragraph"]
        }
        return ["type": "paragraph", "content": [["type": "text", "text": line]]]
    }

    private static func encodeDocument(blocks: [[String: Any]]) -> String? {
        let doc: [String: Any] = ["type": "doc", "content": blocks.isEmpty ? [["type": "paragraph"]] : blocks]
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
