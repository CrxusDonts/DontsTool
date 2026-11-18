import Foundation

public struct WebsiteShortcutEnvironment: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var url: String
    public var aliases: [String]

    public init(key: String, name: String = "", url: String, aliases: [String] = []) {
        self.key = key
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : name
        self.url = url
        self.aliases = aliases
    }

    private enum CodingKeys: String, CodingKey { case key, name, url, aliases }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let key = try values.decode(String.self, forKey: .key)
        let name = values.contains(.name) ? try values.decode(String.self, forKey: .name) : ""
        let url = try values.decode(String.self, forKey: .url)
        let aliases = values.contains(.aliases) ? try values.decode([String].self, forKey: .aliases) : []
        self.init(key: key, name: name, url: url, aliases: aliases)
    }
}

public struct WebsiteShortcut: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var url: String
    public var aliases: [String]
    public var environments: [WebsiteShortcutEnvironment]
    public var pages: [WebsiteShortcutPage]

    public init(key: String, name: String, url: String = "", aliases: [String] = [], environments: [WebsiteShortcutEnvironment] = [], pages: [WebsiteShortcutPage] = []) {
        self.key = key; self.name = name; self.url = url; self.aliases = aliases; self.environments = environments; self.pages = pages
    }

    private enum CodingKeys: String, CodingKey { case key, name, url, aliases, environments, pages }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        name = try values.decode(String.self, forKey: .name)
        url = values.contains(.url) ? try values.decode(String.self, forKey: .url) : ""
        aliases = values.contains(.aliases) ? try values.decode([String].self, forKey: .aliases) : []
        environments = values.contains(.environments) ? try values.decode([WebsiteShortcutEnvironment].self, forKey: .environments) : []
        pages = values.contains(.pages) ? try values.decode([WebsiteShortcutPage].self, forKey: .pages) : []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        try values.encode(name, forKey: .name)
        try values.encode(aliases, forKey: .aliases)
        if !url.isEmpty || environments.isEmpty { try values.encode(url, forKey: .url) }
        if !environments.isEmpty { try values.encode(environments, forKey: .environments) }
        if !pages.isEmpty { try values.encode(pages, forKey: .pages) }
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
    public static let empty = Self(groups: [])
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    public var pageCount: Int { groups.reduce(0) { total, group in total + group.items.reduce(0) { $0 + $1.pages.count } } }
    public var addressCount: Int { groups.reduce(0) { total, group in total + group.items.reduce(0) { $0 + (1 + $1.pages.count) * max(1, $1.environments.count) } } }

    public init(version: Int = 3, groups: [WebsiteShortcutGroup]) {
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
                        let location = "分组 \(index + 1) 的网址 \(offset + 1)"
                        try checkFields(item, allowed: ["key", "name", "url", "aliases", "environments", "pages"], at: location)
                        if item["environments"] != nil, root["version"] as? Int == 1 {
                            throw invalid("多环境网址需要将配置升级为 version: 2")
                        }
                        if item["pages"] != nil, let version = root["version"] as? Int, version < 3 {
                            throw invalid("子页面需要将配置升级为 version: 3")
                        }
                        for (pageIndex, page) in (item["pages"] as? [[String: Any]] ?? []).enumerated() {
                            try checkFields(page, allowed: ["key", "name", "path", "aliases", "urls"], at: "\(location) 的子页面 \(pageIndex + 1)")
                        }
                        for (environmentIndex, environment) in (item["environments"] as? [[String: Any]] ?? []).enumerated() {
                            try checkFields(environment, allowed: ["key", "name", "url", "aliases"], at: "\(location) 的环境 \(environmentIndex + 1)")
                        }
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
        guard (1...3).contains(version) else { throw Self.invalid("不支持配置版本 \(version)，当前支持 version: 1、2 和 3") }
        guard groups.count <= 100, itemCount <= 5000 else { throw Self.invalid("最多支持 100 个分组、5000 个系统") }
        guard addressCount <= 5000 else { throw Self.invalid("最多支持 5000 个网址（包含首页、子页面和所有环境）") }
        let reserved = Set(ToolKind.allCases.flatMap(\.keywords))
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
                let location = "\(group.keyword) \(item.key)"
                try Self.requireLabel(item.key, label: "\(group.keyword) 的项目简称", limit: 64)
                guard !item.key.contains(where: \.isWhitespace) else { throw Self.invalid("项目简称不能包含空格") }
                try Self.requireLabel(item.name, label: "\(location) 的显示名称", limit: 120)
                try Self.validateAliases(item.aliases, key: item.key, seen: &names, location: "分组 \(group.keyword)")
                guard !item.url.isEmpty != !item.environments.isEmpty else {
                    throw Self.invalid("\(location)：请填写一个网址，或添加环境网址，不能同时填写")
                }
                if item.environments.isEmpty {
                    try Self.validateURL(item.url, location: location)
                } else {
                    guard version >= 2 else { throw Self.invalid("多环境网址需要将配置升级为 version: 2 或 3") }
                    guard item.environments.count <= 32 else { throw Self.invalid("\(location)：每个系统最多支持 32 个环境") }
                    var environmentNames = Set<String>()
                    for environmentIndex in item.environments.indices {
                        var environment = item.environments[environmentIndex]
                        environment.key = environment.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        environment.name = environment.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if environment.name.isEmpty { environment.name = environment.key.uppercased() }
                        environment.url = environment.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        environment.aliases = environment.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        guard environment.key.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
                            throw Self.invalid("\(location)：环境简称须以英文字母开头，最多 32 位，可含数字、- 和 _")
                        }
                        try Self.requireLabel(environment.name, label: "\(location) 的环境名称", limit: 120)
                        try Self.validateAliases(environment.aliases, key: environment.key, seen: &environmentNames, location: "\(location) 的环境", normalizeWhitespace: true)
                        try Self.validateURL(environment.url, location: "\(location) \(environment.key)")
                        item.environments[environmentIndex] = environment
                    }
                }
                guard item.pages.isEmpty || version == 3 else { throw Self.invalid("子页面需要将配置升级为 version: 3") }
                guard item.pages.count <= 100 else { throw Self.invalid("\(location)：每个系统最多支持 100 个子页面") }
                var pageNames = Set(["home", "首页"].map(Self.environmentLookupKey))
                let environmentKeys = Set(item.environments.map(\.key))
                for pageIndex in item.pages.indices {
                    var page = item.pages[pageIndex]
                    page.key = page.key.trimmingCharacters(in: .whitespacesAndNewlines)
                    page.name = page.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    page.aliases = page.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    let pageLocation = "\(location) 的子页面 \(page.key)"
                    try Self.requireLabel(page.key, label: "\(location) 的子页面简称", limit: 64)
                    guard !page.key.contains(where: \.isWhitespace) else { throw Self.invalid("子页面简称不能包含空格") }
                    try Self.requireLabel(page.name, label: "\(pageLocation) 的显示名称", limit: 120)
                    guard !([page.key] + page.aliases).contains(where: { ["home", "首页"].contains(Self.environmentLookupKey($0)) }) else {
                        throw Self.invalid("\(pageLocation)：home 和首页已被内置首页占用")
                    }
                    try Self.validateAliases(page.aliases, key: page.key, seen: &pageNames, location: "\(location) 的子页面", normalizeWhitespace: true)
                    item.pages[pageIndex] = try page.validated(environmentKeys: environmentKeys, location: pageLocation)
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

    static func environmentLookupKey(_ text: String) -> String {
        lookupKey(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func validateAliases(_ aliases: [String], key: String, seen: inout Set<String>, location: String, normalizeWhitespace: Bool = false) throws {
        guard aliases.count <= 30 else { throw invalid("\(location)：最多支持 30 个别名") }
        for alias in [key] + aliases {
            try requireLabel(alias, label: "\(location) 的简称或别名", limit: 120)
            let normalized = normalizeWhitespace ? environmentLookupKey(alias) : lookupKey(alias)
            guard seen.insert(normalized).inserted else { throw invalid("\(location)中的简称或别名“\(alias)”重复") }
        }
    }

    static func validateURL(_ value: String, location: String) throws {
        guard value.utf8.count <= 8192, !value.contains("\\"), !value.contains(where: { $0.isWhitespace }),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw invalid("\(location)：请输入完整 HTTP/HTTPS 网址，不含空白或账号密码")
        }
    }

    private static func requireLabel(_ value: String, label: String, limit: Int) throws {
        guard !value.isEmpty, value.count <= limit, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw invalid("\(label)不能为空、包含控制字符或超过 \(limit) 字")
        }
    }
    private static func checkFields(_ object: [String: Any], allowed: Set<String>, at location: String) throws {
        if let field = Set(object.keys).subtracting(allowed).sorted().first { throw invalid("\(location)包含未知字段：\(field)") }
    }
    static func invalid(_ message: String) -> ActionError { .invalidInput(message) }
}
