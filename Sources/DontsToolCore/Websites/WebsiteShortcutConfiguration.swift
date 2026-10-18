import Foundation

public struct WebsiteShortcut: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var url: String
    public var aliases: [String]

    public init(key: String, name: String, url: String, aliases: [String] = []) {
        self.key = key; self.name = name; self.url = url; self.aliases = aliases
    }

    private enum CodingKeys: String, CodingKey { case key, name, url, aliases }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        name = try values.decode(String.self, forKey: .name)
        url = try values.decode(String.self, forKey: .url)
        aliases = values.contains(.aliases) ? try values.decode([String].self, forKey: .aliases) : []
    }
}

public struct WebsiteShortcutGroup: Codable, Equatable, Sendable {
    public var keyword: String
    public var name: String
    public var items: [WebsiteShortcut]

    public init(keyword: String, name: String, items: [WebsiteShortcut] = []) {
        self.keyword = keyword; self.name = name; self.items = items
    }
}

public struct WebsiteShortcutConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var groups: [WebsiteShortcutGroup]
    public static let maximumBytes = 1_048_576
    public static let empty = Self(version: 1, groups: [])
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    public init(version: Int = 1, groups: [WebsiteShortcutGroup]) {
        self.version = version; self.groups = groups
    }

    public static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= maximumBytes else { throw invalid("配置文件不能超过 1 MiB") }
        let data = Data(text.utf8)
        do {
            // Catch misspelled fields instead of silently dropping entries on round-trip.
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw invalid("配置根节点必须是对象")
            }
            try checkFields(root, allowed: ["version", "groups"], at: "配置")
            if let groups = root["groups"] as? [[String: Any]] {
                for (index, group) in groups.enumerated() {
                    try checkFields(group, allowed: ["keyword", "name", "items"], at: "分组 \(index + 1)")
                    for (offset, item) in (group["items"] as? [[String: Any]] ?? []).enumerated() {
                        try checkFields(item, allowed: ["key", "name", "url", "aliases"], at: "分组 \(index + 1) 的网址 \(offset + 1)")
                    }
                }
            }
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch let error as ActionError { throw error }
        catch let error as DecodingError {
            let path: String
            switch error {
            case .keyNotFound(let key, let context): path = (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath.map(\.stringValue).joined(separator: ".")
            @unknown default: path = ""
            }
            throw invalid("JSON 字段缺失或类型错误\(path.isEmpty ? "" : "：" + path)")
        } catch { throw invalid("JSON 格式错误，请检查引号、逗号和括号") }
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Both manual edits and JSON imports pass through the same all-or-nothing validation.
    public func validated() throws -> Self {
        guard version == 1 else { throw Self.invalid("不支持配置版本 \(version)，当前仅支持 version: 1") }
        guard groups.count <= 100, itemCount <= 5000 else { throw Self.invalid("最多支持 100 个分组、5000 个网址") }
        let reserved = Set(ToolKind.allCases.flatMap(\.keywords) + ["kb", "collect", "inbox", "g", "bing", "bd", "ddg"])
        var result = self
        var keywords = Set<String>()
        for index in result.groups.indices {
            var group = result.groups[index]
            group.keyword = group.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            group.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard group.keyword.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
                throw Self.invalid("分组 \(index + 1)：前缀须以英文字母开头，最多 32 位，可含数字、- 和 _")
            }
            guard !reserved.contains(group.keyword) else { throw Self.invalid("前缀 \(group.keyword) 已被内置功能占用，请换一个") }
            guard keywords.insert(group.keyword).inserted else { throw Self.invalid("前缀 \(group.keyword) 重复") }
            try Self.requireLabel(group.name, label: "\(group.keyword) 的分组名称", limit: 120)
            var names = Set<String>()
            for offset in group.items.indices {
                var item = group.items[offset]
                item.key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
                item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                item.url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
                item.aliases = item.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                try Self.requireLabel(item.key, label: "\(group.keyword) 的项目简称", limit: 64)
                guard !item.key.contains(where: \.isWhitespace) else { throw Self.invalid("项目简称不能包含空格") }
                try Self.requireLabel(item.name, label: "\(group.keyword) \(item.key) 的显示名称", limit: 120)
                guard item.aliases.count <= 30 else { throw Self.invalid("每个网址最多支持 30 个别名") }
                for alias in [item.key] + item.aliases {
                    try Self.requireLabel(alias, label: "\(group.keyword) \(item.key) 的简称或别名", limit: 120)
                    guard names.insert(Self.lookupKey(alias)).inserted else {
                        throw Self.invalid("分组 \(group.keyword) 中的简称或别名“\(alias)”重复")
                    }
                }
                guard item.url.utf8.count <= 8192, !item.url.contains(where: { $0.isWhitespace }),
                      item.url.rangeOfCharacter(from: .controlCharacters) == nil,
                      let url = URL(string: item.url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                      let host = components.host, !host.isEmpty,
                      components.user == nil, components.password == nil,
                      components.port.map({ (1...65535).contains($0) }) ?? true else {
                    throw Self.invalid("\(group.keyword) \(item.key)：请输入完整 HTTP/HTTPS 网址，不含空白或账号密码")
                }
                group.items[offset] = item
            }
            result.groups[index] = group
        }
        guard try result.json().utf8.count <= Self.maximumBytes else { throw Self.invalid("配置文件不能超过 1 MiB") }
        return result
    }

    static func lookupKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func requireLabel(_ value: String, label: String, limit: Int) throws {
        guard !value.isEmpty, value.count <= limit, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw invalid("\(label)不能为空、包含控制字符或超过 \(limit) 字")
        }
    }
    private static func checkFields(_ object: [String: Any], allowed: Set<String>, at location: String) throws {
        if let field = Set(object.keys).subtracting(allowed).sorted().first { throw invalid("\(location)包含未知字段：\(field)") }
    }
    private static func invalid(_ message: String) -> ActionError { .invalidInput(message) }
}
