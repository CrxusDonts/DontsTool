import Foundation

public struct SearchEngineDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var keyword: String
    public var urlTemplate: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, keyword: String, urlTemplate: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.urlTemplate = urlTemplate
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, name, keyword, urlTemplate, isEnabled }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownSearchFields(decoder, allowed: ["id", "name", "keyword", "urlTemplate", "isEnabled"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        keyword = try values.decode(String.self, forKey: .keyword)
        urlTemplate = try values.decode(String.self, forKey: .urlTemplate)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
    }

    public func searchURL(for query: String) -> URL? {
        guard (try? validateTemplate()) != nil else { return nil }
        let encoded = query.utf8.map { byte -> String in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
        return URL(string: urlTemplate.replacingOccurrences(of: "{query}", with: encoded), encodingInvalidCharacters: false)
    }

    fileprivate func validateTemplate() throws {
        let location = name.isEmpty ? id : name
        let invalid = ActionError.invalidInput("\(location)：请输入带 {query} 的完整 HTTP/HTTPS 网址，不含空白或账号密码；占位符只能出现在路径、查询或片段中")
        let remainder = urlTemplate.replacingOccurrences(of: "{query}", with: "")
        guard urlTemplate.utf8.count <= 8192,
              urlTemplate.contains("{query}"), !remainder.contains("{"), !remainder.contains("}"),
              !urlTemplate.contains("\\"), !urlTemplate.contains(where: \.isWhitespace),
              urlTemplate.rangeOfCharacter(from: .controlCharacters) == nil,
              let schemeEnd = urlTemplate.range(of: "://") else { throw invalid }
        let authorityStart = schemeEnd.upperBound
        let authorityEnd = urlTemplate[authorityStart...].firstIndex(where: { "/?#".contains($0) }) ?? urlTemplate.endIndex
        guard !urlTemplate[..<authorityEnd].contains("{query}") else { throw invalid }
        let probe = urlTemplate.replacingOccurrences(of: "{query}", with: "searchQuery")
        guard let url = URL(string: probe, encodingInvalidCharacters: false),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              !host.contains("%"),
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw invalid }
    }
}

public struct SearchEngineConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var defaultEngineID: String
    public var engines: [SearchEngineDefinition]
    public static let maximumBytes = 1_048_576
    public static let reservedKeywords = Set(ToolKind.allCases.flatMap(\.keywords) + [
        "kb", "collect", "inbox", "open", "idea", "calc", "=", "gm", "gemini", "file"
    ])

    public init(version: Int = 1, defaultEngineID: String, engines: [SearchEngineDefinition]) {
        self.version = version
        self.defaultEngineID = defaultEngineID
        self.engines = engines
    }

    public static let builtIn = Self(defaultEngineID: "google", engines: [
        .init(id: "google", name: "Google", keyword: "g", urlTemplate: "https://www.google.com/search?q={query}"),
        .init(id: "bing", name: "必应", keyword: "bing", urlTemplate: "https://www.bing.com/search?q={query}"),
        .init(id: "baidu", name: "百度", keyword: "bd", urlTemplate: "https://www.baidu.com/s?wd={query}"),
        .init(id: "ddg", name: "DuckDuckGo", keyword: "ddg", urlTemplate: "https://duckduckgo.com/?q={query}"),
        .init(id: "github", name: "GitHub", keyword: "gh", urlTemplate: "https://github.com/search?q={query}")
    ])

    public var enabledEngines: [SearchEngineDefinition] { engines.filter(\.isEnabled) }
    public var defaultEngine: SearchEngineDefinition {
        engines.first { $0.id == defaultEngineID && $0.isEnabled } ?? enabledEngines.first ?? Self.builtIn.engines[0]
    }

    private enum CodingKeys: String, CodingKey { case version, defaultEngineID, engines }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownSearchFields(decoder, allowed: ["version", "defaultEngineID", "engines"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        defaultEngineID = try values.decode(String.self, forKey: .defaultEngineID)
        engines = try values.decode([SearchEngineDefinition].self, forKey: .engines)
    }

    public func validated(reservedKeywords: Set<String> = Self.reservedKeywords) throws -> Self {
        guard version == 1 else { throw ActionError.invalidInput("不支持搜索配置版本 \(version)，当前支持 version: 1") }
        guard !engines.isEmpty, engines.count <= 100 else { throw ActionError.invalidInput("请配置 1 至 100 个搜索引擎") }
        var result = self
        var ids = Set<String>()
        var keywords = Set<String>()
        let reserved = Set(reservedKeywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for index in result.engines.indices {
            var engine = result.engines[index]
            try Self.requireLabel(engine.id, label: "引擎 ID", limit: 120)
            guard !engine.id.contains(where: \.isWhitespace) else { throw ActionError.invalidInput("引擎 ID 不能包含空白") }
            guard ids.insert(engine.id).inserted else { throw ActionError.invalidInput("引擎 ID \(engine.id) 重复") }
            engine.name = engine.name.trimmingCharacters(in: .whitespacesAndNewlines)
            engine.keyword = engine.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            engine.urlTemplate = engine.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.requireLabel(engine.name, label: "引擎名称", limit: 120)
            guard engine.keyword.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
                throw ActionError.invalidInput("\(engine.name)：快捷词须以英文字母开头，最多 32 位，可含数字、- 和 _")
            }
            guard keywords.insert(engine.keyword).inserted else { throw ActionError.invalidInput("快捷词 \(engine.keyword) 重复") }
            guard !engine.isEnabled || !reserved.contains(engine.keyword) else {
                throw ActionError.invalidInput("快捷词 \(engine.keyword) 已被其他功能占用，请换一个")
            }
            try engine.validateTemplate()
            result.engines[index] = engine
        }
        guard result.engines.contains(where: { $0.id == defaultEngineID && $0.isEnabled }) else {
            throw ActionError.invalidInput("默认搜索引擎必须存在且已启用")
        }
        guard try result.json().utf8.count <= Self.maximumBytes else { throw ActionError.invalidInput("配置文件不能超过 1 MiB") }
        return result
    }

    public static func decode(_ text: String, reservedKeywords: Set<String> = Self.reservedKeywords) throws -> Self {
        guard text.utf8.count <= maximumBytes else { throw ActionError.invalidInput("配置文件不能超过 1 MiB") }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(text.utf8)).validated(reservedKeywords: reservedKeywords)
        } catch let error as ActionError { throw error }
        catch let error as DecodingError {
            let context: DecodingError.Context
            let path: String
            switch error {
            case .keyNotFound(let key, let value):
                context = value
                path = (value.codingPath + [key]).map(\.stringValue).joined(separator: ".")
            case .typeMismatch(_, let value), .valueNotFound(_, let value), .dataCorrupted(let value):
                context = value
                path = value.codingPath.map(\.stringValue).joined(separator: ".")
            @unknown default: throw ActionError.invalidInput("搜索配置 JSON 格式错误")
            }
            throw ActionError.invalidInput("JSON 字段缺失或格式错误\(path.isEmpty ? "" : "：" + path)（\(context.debugDescription)）")
        } catch { throw ActionError.invalidInput("JSON 格式错误，请检查引号、逗号和括号") }
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private static func requireLabel(_ value: String, label: String, limit: Int) throws {
        guard !value.isEmpty, value.count <= limit, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ActionError.invalidInput("\(label)不能为空、包含控制字符或超过 \(limit) 字")
        }
    }
}

private struct SearchConfigurationKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownSearchFields(_ decoder: any Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: SearchConfigurationKey.self)
    if let key = values.allKeys.map(\.stringValue).filter({ !allowed.contains($0) }).sorted().first {
        throw ActionError.invalidInput("搜索配置包含未知字段：\(key)")
    }
}
