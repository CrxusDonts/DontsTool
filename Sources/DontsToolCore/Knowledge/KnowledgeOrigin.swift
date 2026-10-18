import Foundation

/// The configured website origin is the native plugin's authentication boundary.
public struct KnowledgeOrigin: Equatable, Sendable {
    public enum ValidationError: LocalizedError, Sendable {
        case invalidOrigin

        public var errorDescription: String? {
            "请输入 HTTPS 知识库来源，例如 https://kb.example.com；本地开发可使用 HTTP localhost。"
        }
    }

    public let baseURL: URL

    public init(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || (scheme == "http" && Self.isLoopback(host))
        else { throw ValidationError.invalidOrigin }

        components.scheme = scheme
        components.host = host
        components.path = ""
        if components.port == Self.defaultPort(for: scheme) { components.port = nil }
        guard let url = components.url else { throw ValidationError.invalidOrigin }
        baseURL = url
    }

    public func url(for request: KnowledgeOpenRequest) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/tool"
        var items = [URLQueryItem(name: "mode", value: request.surface.rawValue)]
        if request.surface == .editor {
            if let id = request.documentID, !id.isEmpty { items.append(URLQueryItem(name: "documentId", value: id)) }
            if let id = request.blockID, !id.isEmpty { items.append(URLQueryItem(name: "blockId", value: id)) }
        }
        if request.surface == .search, let query = request.query, !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        components.queryItems = items
        return components.url!
    }

    /// Paths and query strings may vary, while scheme, host, and effective port must match.
    public func contains(_ url: URL) -> Bool {
        guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
              candidate.user == nil, candidate.password == nil,
              let expected = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = candidate.scheme?.lowercased(),
              scheme == expected.scheme,
              candidate.host?.lowercased() == expected.host?.lowercased()
        else { return false }
        return (candidate.port ?? Self.defaultPort(for: scheme)) == (expected.port ?? Self.defaultPort(for: scheme))
    }

    private static func defaultPort(for scheme: String) -> Int { scheme == "https" ? 443 : 80 }
    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
    }
}
