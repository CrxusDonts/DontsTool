import Combine
import Foundation

public enum PluginSourceLocation: Equatable, Sendable {
    case gitHubRepo(owner: String, repo: String)
    case catalogURL(URL)

    public var canonicalString: String {
        switch self {
        case let .gitHubRepo(owner, repo):
            "\(owner)/\(repo)"
        case let .catalogURL(url):
            url.absoluteString
        }
    }
}

public struct PluginSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let location: String
    public let isBuiltIn: Bool

    public init(id: String, name: String, location: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.location = location
        self.isBuiltIn = isBuiltIn
    }

    public var parsedLocation: PluginSourceLocation? {
        try? PluginSourceStore.parseLocation(location)
    }

    public var canonicalRepoIdentifier: String {
        parsedLocation?.canonicalString ?? location
    }
}

public enum PluginSourceError: LocalizedError, Equatable, Sendable {
    case invalidLocation(String)
    case duplicateSource(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocation(let raw):
            "插件源地址格式无效（请输入 owner/repo、GitHub 仓库链接或 HTTPS catalog.json 链接）：\(raw)"
        case .duplicateSource(let location):
            "插件源已存在：\(location)"
        }
    }
}

@MainActor
public final class PluginSourceStore: ObservableObject {
    public nonisolated static let storageKey = "dontstool.plugins.sources"
    public nonisolated static let officialRepoLocation = "CrxusDonts/DontsTool-Plugins"

    public nonisolated static let officialSource = PluginSource(
        id: "builtin.official",
        name: "DontsTool 官方插件仓库",
        location: officialRepoLocation,
        isBuiltIn: true
    )

    private let defaults: UserDefaults
    private var customSources: [PluginSource]

    @Published public private(set) var sources: [PluginSource]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.loadCustomSources(from: defaults)
        self.customSources = loaded
        self.sources = [Self.officialSource] + loaded
    }

    public func source(for id: String) -> PluginSource? {
        sources.first { $0.id == id }
    }

    @discardableResult
    public func addSource(location rawLocation: String, name rawName: String? = nil) throws -> PluginSource {
        let parsed = try Self.parseLocation(rawLocation)
        let canonical = parsed.canonicalString

        let isDuplicate = sources.contains {
            $0.canonicalRepoIdentifier.caseInsensitiveCompare(canonical) == .orderedSame
        }
        guard !isDuplicate else {
            throw PluginSourceError.duplicateSource(canonical)
        }

        let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName: String
        if !trimmedName.isEmpty {
            resolvedName = trimmedName
        } else {
            switch parsed {
            case let .gitHubRepo(owner, repo):
                resolvedName = "\(owner)/\(repo)"
            case let .catalogURL(url):
                resolvedName = url.host ?? url.absoluteString
            }
        }

        let created = PluginSource(
            id: UUID().uuidString,
            name: resolvedName,
            location: canonical,
            isBuiltIn: false
        )
        customSources.append(created)
        syncAndPersist()
        return created
    }

    @discardableResult
    public func removeSource(id: String) -> Bool {
        guard let index = customSources.firstIndex(where: { $0.id == id && !$0.isBuiltIn }) else {
            return false
        }
        customSources.remove(at: index)
        syncAndPersist()
        return true
    }

    public nonisolated static func normalizeLocation(_ raw: String) throws -> String {
        try parseLocation(raw).canonicalString
    }

    public nonisolated static func parseLocation(_ raw: String) throws -> PluginSourceLocation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginSourceError.invalidLocation(raw)
        }

        if trimmed.contains("://") {
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https",
                  let host = url.host?.lowercased(),
                  !host.isEmpty else {
                throw PluginSourceError.invalidLocation(raw)
            }

            if host == "github.com" || host == "www.github.com" {
                let components = url.pathComponents.filter { $0 != "/" }
                guard components.count >= 2 else {
                    throw PluginSourceError.invalidLocation(raw)
                }
                if components.count > 2,
                   url.path.lowercased().hasSuffix(".json") {
                    return .catalogURL(url)
                }
                if components.count == 2 || (components.count >= 3 && components[2] == "tree") {
                    let owner = components[0]
                    let repo = stripGitSuffix(components[1])
                    guard isValidGitHubSegment(owner), isValidGitHubSegment(repo) else {
                        throw PluginSourceError.invalidLocation(raw)
                    }
                    return .gitHubRepo(owner: owner, repo: repo)
                }
                throw PluginSourceError.invalidLocation(raw)
            }

            return .catalogURL(url)
        }

        var candidate = trimmed
        let lower = candidate.lowercased()
        if lower.hasPrefix("github.com/") {
            candidate = String(candidate.dropFirst("github.com/".count))
        } else if lower.hasPrefix("www.github.com/") {
            candidate = String(candidate.dropFirst("www.github.com/".count))
        }

        while candidate.hasSuffix("/") {
            candidate.removeLast()
        }

        let parts = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw PluginSourceError.invalidLocation(raw)
        }

        let owner = String(parts[0])
        let repo = stripGitSuffix(String(parts[1]))
        guard isValidGitHubSegment(owner), isValidGitHubSegment(repo) else {
            throw PluginSourceError.invalidLocation(raw)
        }
        return .gitHubRepo(owner: owner, repo: repo)
    }

    // MARK: - Private

    private func syncAndPersist() {
        sources = [Self.officialSource] + customSources
        if let encoded = try? JSONEncoder().encode(customSources) {
            defaults.set(encoded, forKey: Self.storageKey)
        }
    }

    private static func loadCustomSources(from defaults: UserDefaults) -> [PluginSource] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PluginSource].self, from: data) else {
            return []
        }
        var seen: Set<String> = [officialRepoLocation.lowercased()]
        var result: [PluginSource] = []
        for item in decoded where !item.isBuiltIn {
            guard let parsed = try? parseLocation(item.location) else { continue }
            let canonical = parsed.canonicalString
            if seen.insert(canonical.lowercased()).inserted {
                result.append(PluginSource(
                    id: item.id,
                    name: item.name,
                    location: canonical,
                    isBuiltIn: false
                ))
            }
        }
        return result
    }

    private nonisolated static func stripGitSuffix(_ value: String) -> String {
        if value.lowercased().hasSuffix(".git"), value.count > 4 {
            return String(value.dropLast(4))
        }
        return value
    }

    private nonisolated static func isValidGitHubSegment(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "-"
                || scalar == "_"
                || scalar == "."
        }
    }
}
