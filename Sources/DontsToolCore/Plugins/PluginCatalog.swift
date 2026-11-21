import Foundation

public struct PluginCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceName: String
    public let plugins: [PluginCatalogEntry]

    public init(schemaVersion: Int = 1, sourceName: String, plugins: [PluginCatalogEntry]) {
        self.schemaVersion = schemaVersion
        self.sourceName = sourceName
        self.plugins = plugins
    }
}

public struct PluginCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String?
    public let version: String
    public let minHostVersion: String?
    public let downloadURL: String?
    public let subpath: String?
    public let sha256: String?
    public let ed25519Signature: String?
    public let official: Bool?

    public init(
        id: String,
        name: String,
        summary: String? = nil,
        version: String,
        minHostVersion: String? = nil,
        downloadURL: String? = nil,
        subpath: String? = nil,
        sha256: String? = nil,
        ed25519Signature: String? = nil,
        official: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.version = version
        self.minHostVersion = minHostVersion
        self.downloadURL = downloadURL
        self.subpath = subpath
        self.sha256 = sha256
        self.ed25519Signature = ed25519Signature
        self.official = official
    }
}

public struct PluginInstallMetadata: Codable, Equatable, Sendable {
    public let pluginID: String
    public let version: String
    public let sourceRepo: String
    public let catalogURL: String?
    public let sha256: String?
    public let installedAt: Date

    public init(
        pluginID: String,
        version: String,
        sourceRepo: String,
        catalogURL: String? = nil,
        sha256: String? = nil,
        installedAt: Date = Date()
    ) {
        self.pluginID = pluginID
        self.version = version
        self.sourceRepo = sourceRepo
        self.catalogURL = catalogURL
        self.sha256 = sha256
        self.installedAt = installedAt
    }
}

public enum PluginCatalogError: LocalizedError, Equatable, Sendable {
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case emptySourceName
    case emptyPlugins
    case invalidPluginID(String)
    case duplicatePluginID(String)
    case emptyField(String, pluginID: String)
    case invalidDownloadURL(String, pluginID: String)
    case invalidSHA256(String, pluginID: String)
    case invalidSubpath(String, pluginID: String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): "插件索引 JSON 格式无效：\(detail)"
        case .unsupportedSchemaVersion(let version): "不支持的插件索引版本：\(version)"
        case .emptySourceName: "插件索引缺少 sourceName"
        case .emptyPlugins: "插件索引不包含任何插件条目"
        case .invalidPluginID(let id): "插件索引条目 ID 格式不合法：\(id)"
        case .duplicatePluginID(let id): "插件索引存在重复插件 ID：\(id)"
        case .emptyField(let field, let pluginID): "插件 \(pluginID) 缺少字段 \(field)"
        case .invalidDownloadURL(let url, let pluginID): "插件 \(pluginID) 下载地址无效（仅允许 HTTPS）：\(url)"
        case .invalidSHA256(let hash, let pluginID): "插件 \(pluginID) SHA-256 格式无效：\(hash)"
        case .invalidSubpath(let path, let pluginID): "插件 \(pluginID) 子路径不安全：\(path)"
        }
    }
}

public enum PluginCatalogValidator {
    public static func decodeAndValidate(_ data: Data) throws -> PluginCatalog {
        let catalog: PluginCatalog
        do {
            catalog = try JSONDecoder().decode(PluginCatalog.self, from: data)
        } catch {
            throw PluginCatalogError.invalidJSON(error.localizedDescription)
        }
        try validate(catalog)
        return catalog
    }

    public static func validate(_ catalog: PluginCatalog) throws {
        guard catalog.schemaVersion == 1 else {
            throw PluginCatalogError.unsupportedSchemaVersion(catalog.schemaVersion)
        }
        guard !catalog.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginCatalogError.emptySourceName
        }
        guard !catalog.plugins.isEmpty else {
            throw PluginCatalogError.emptyPlugins
        }

        var seenIDs: Set<String> = []
        for entry in catalog.plugins {
            let trimmedID = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard PluginManifestLoader.isValidPluginID(trimmedID) else {
                throw PluginCatalogError.invalidPluginID(entry.id)
            }
            guard seenIDs.insert(trimmedID).inserted else {
                throw PluginCatalogError.duplicatePluginID(trimmedID)
            }
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginCatalogError.emptyField("name", pluginID: trimmedID)
            }
            guard !entry.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginCatalogError.emptyField("version", pluginID: trimmedID)
            }

            if let rawURL = entry.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty {
                guard let url = URL(string: rawURL),
                      url.scheme?.lowercased() == "https",
                      let host = url.host, !host.isEmpty else {
                    throw PluginCatalogError.invalidDownloadURL(rawURL, pluginID: trimmedID)
                }
            }

            if let rawHash = entry.sha256?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHash.isEmpty {
                guard isValidSHA256Hex(rawHash) else {
                    throw PluginCatalogError.invalidSHA256(rawHash, pluginID: trimmedID)
                }
            }

            if let rawSubpath = entry.subpath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawSubpath.isEmpty {
                let segments = rawSubpath.split(separator: "/", omittingEmptySubsequences: false)
                guard !rawSubpath.hasPrefix("/"),
                      !rawSubpath.hasPrefix("~"),
                      !segments.contains(".."),
                      !segments.contains("") else {
                    throw PluginCatalogError.invalidSubpath(rawSubpath, pluginID: trimmedID)
                }
            }
        }
    }

    public static func detectSourceConflict(
        incomingPluginID: String,
        incomingSourceRepo: String,
        existingMetadata: PluginInstallMetadata?
    ) -> Bool {
        guard let existingMetadata else { return false }
        guard existingMetadata.pluginID == incomingPluginID else { return false }
        return existingMetadata.sourceRepo.caseInsensitiveCompare(incomingSourceRepo) != .orderedSame
    }

    private static func isValidSHA256Hex(_ string: String) -> Bool {
        guard string.count == 64 else { return false }
        return string.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9")
                || (scalar >= "a" && scalar <= "f")
                || (scalar >= "A" && scalar <= "F")
        }
    }
}
