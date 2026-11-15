import Foundation

public struct WebsiteShortcutPage: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var path: String
    public var aliases: [String]
    public var urls: [String: String]

    public init(key: String, name: String, path: String = "", aliases: [String] = [], urls: [String: String] = [:]) {
        self.key = key
        self.name = name
        self.path = path
        self.aliases = aliases
        self.urls = urls
    }

    private enum CodingKeys: String, CodingKey { case key, name, path, aliases, urls }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        name = try values.decode(String.self, forKey: .name)
        path = values.contains(.path) ? try values.decode(String.self, forKey: .path) : ""
        aliases = values.contains(.aliases) ? try values.decode([String].self, forKey: .aliases) : []
        urls = values.contains(.urls) ? try values.decode([String: String].self, forKey: .urls) : [:]
    }

    public func resolvedURL(baseURL: String, environmentKey: String? = nil) throws -> URL {
        if let environmentKey,
           let override = urls[Self.overrideKey(environmentKey)] {
            try WebsiteShortcutConfiguration.validateURL(override, location: "子页面 \(key)")
            return URL(string: override)!
        }
        try validatePath(location: "子页面 \(key)")
        guard !path.isEmpty else {
            throw WebsiteShortcutConfiguration.invalid("子页面 \(key)：缺少当前环境的网址或通用路径")
        }
        if !path.hasPrefix("/") { return URL(string: path)! }
        try WebsiteShortcutConfiguration.validateURL(baseURL, location: "子页面 \(key) 的基础网址")
        var origin = URLComponents(string: baseURL)!
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        guard let base = origin.url, let resolved = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw WebsiteShortcutConfiguration.invalid("子页面 \(key)：无法组合基础网址和页面路径")
        }
        return resolved
    }

    func validated(environmentKeys: Set<String>, location: String) throws -> Self {
        try validatePath(location: location)
        guard !environmentKeys.isEmpty || urls.isEmpty else {
            throw WebsiteShortcutConfiguration.invalid("\(location)：单网址系统的子页面不能填写环境网址覆盖项")
        }
        var result = self
        result.urls = [:]
        for (key, value) in urls {
            let normalized = Self.overrideKey(key)
            guard environmentKeys.contains(normalized) else {
                throw WebsiteShortcutConfiguration.invalid("\(location)：网址覆盖项“\(key)”必须使用已有环境的简称")
            }
            guard result.urls[normalized] == nil else {
                throw WebsiteShortcutConfiguration.invalid("\(location)：环境网址覆盖项“\(key)”重复")
            }
            try WebsiteShortcutConfiguration.validateURL(value, location: "\(location) \(normalized)")
            result.urls[normalized] = value
        }
        guard !path.isEmpty || (!environmentKeys.isEmpty && Set(result.urls.keys) == environmentKeys) else {
            throw WebsiteShortcutConfiguration.invalid("\(location)：请填写页面路径，或为所有环境填写完整网址")
        }
        return result
    }

    private func validatePath(location: String) throws {
        guard !path.isEmpty else { return }
        if path.hasPrefix("/") {
            guard !path.hasPrefix("//"), !path.contains("\\"), path.utf8.count <= 8192,
                  !path.contains(where: \.isWhitespace), path.rangeOfCharacter(from: .controlCharacters) == nil,
                  URL(string: path) != nil else {
                throw WebsiteShortcutConfiguration.invalid("\(location)：页面路径须以单个 / 开头，且不能包含空白、反斜线或控制字符")
            }
        } else {
            try WebsiteShortcutConfiguration.validateURL(path, location: location)
        }
    }

    private static func overrideKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
