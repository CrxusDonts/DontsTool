import CryptoKit
import Foundation

public enum CloudSyncValidationError: LocalizedError, Equatable {
    case invalidServerURL
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "请输入有效的同步服务地址（需为 HTTPS；本地调试支持 http://localhost 或 127.0.0.1），不能包含账号、查询参数或片段。"
        case .missingToken:
            "请先配置并保存同步密钥（Sync Token）。"
        }
    }
}

public struct CloudSyncOrigin: Equatable, Hashable, Sendable {
    public let baseURL: URL
    public let originString: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw CloudSyncValidationError.invalidServerURL
        }

        let isLoopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw CloudSyncValidationError.invalidServerURL
        }
        if let port = components.port, !(1...65535).contains(port) {
            throw CloudSyncValidationError.invalidServerURL
        }

        var normalizedComponents = components
        normalizedComponents.scheme = scheme
        normalizedComponents.host = host.lowercased()
        let cleanedPath = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        normalizedComponents.path = cleanedPath
        guard let url = normalizedComponents.url else {
            throw CloudSyncValidationError.invalidServerURL
        }
        baseURL = url
        originString = url.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    public func endpointURL(_ path: String, queryItems: [URLQueryItem] = []) -> URL {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let target = baseURL.appendingPathComponent(cleanPath)
        guard !queryItems.isEmpty,
              var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            return target
        }
        components.queryItems = queryItems
        return components.url ?? target
    }

    public func webSocketURL() -> URL {
        var components = URLComponents(url: endpointURL("v1/ws"), resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components?.url ?? endpointURL("v1/ws")
    }
}

public enum SyncDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }
}

public enum SyncJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum SyncEntityKind: String, Codable, Sendable {
    case config
    case note
}

public enum SyncEntityKey {
    public static let websites = "config:websites"
    public static let searchEngines = "config:searchEngines"
    public static let settings = "config:settings"

    public static func note(_ id: UUID) -> String {
        "note:\(id.uuidString.lowercased())"
    }

    public static func parseNoteID(_ key: String) -> UUID? {
        guard key.hasPrefix("note:") else { return nil }
        return UUID(uuidString: String(key.dropFirst("note:".count)))
    }
}

public struct SyncedNoteAssetRef: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String

    public init(relativePath: String, sha256: String) {
        self.relativePath = relativePath
        self.sha256 = sha256
    }
}

public struct SyncedNotePayload: Codable, Equatable, Sendable {
    public let record: LocalNoteRecord
    public let isTrashed: Bool
    public let assets: [SyncedNoteAssetRef]

    public init(record: LocalNoteRecord, isTrashed: Bool, assets: [SyncedNoteAssetRef]) {
        self.record = record
        self.isTrashed = isTrashed
        self.assets = assets.sorted { $0.relativePath < $1.relativePath }
    }
}

public struct SyncMutationInput: Codable, Equatable, Sendable {
    public let entityKey: String
    public let kind: SyncEntityKind
    public let deleted: Bool
    public let updatedAt: Date
    public let contentHash: String
    public let payload: String?
    public let payloadBlobSha256: String?

    public init(
        entityKey: String,
        kind: SyncEntityKind,
        deleted: Bool,
        updatedAt: Date,
        contentHash: String,
        payload: String? = nil,
        payloadBlobSha256: String? = nil
    ) {
        self.entityKey = entityKey
        self.kind = kind
        self.deleted = deleted
        self.updatedAt = updatedAt
        self.contentHash = contentHash
        self.payload = payload
        self.payloadBlobSha256 = payloadBlobSha256
    }
}

public struct SyncItemRecord: Codable, Equatable, Sendable {
    public let entityKey: String
    public let kind: SyncEntityKind
    public let revision: Int64
    public let deleted: Bool
    public let updatedAt: Date
    public let contentHash: String
    public let deviceId: String
    public let payload: String?
    public let payloadBlobSha256: String?

    public init(
        entityKey: String,
        kind: SyncEntityKind,
        revision: Int64,
        deleted: Bool,
        updatedAt: Date,
        contentHash: String,
        deviceId: String,
        payload: String? = nil,
        payloadBlobSha256: String? = nil
    ) {
        self.entityKey = entityKey
        self.kind = kind
        self.revision = revision
        self.deleted = deleted
        self.updatedAt = updatedAt
        self.contentHash = contentHash
        self.deviceId = deviceId
        self.payload = payload
        self.payloadBlobSha256 = payloadBlobSha256
    }
}

public struct SyncPushRequest: Codable, Equatable, Sendable {
    public let deviceId: String
    public let mutations: [SyncMutationInput]

    public init(deviceId: String, mutations: [SyncMutationInput]) {
        self.deviceId = deviceId
        self.mutations = mutations
    }
}

public struct SyncPushResponse: Codable, Equatable, Sendable {
    public let revision: Int64
    public let appliedKeys: [String]

    public init(revision: Int64, appliedKeys: [String]) {
        self.revision = revision
        self.appliedKeys = appliedKeys
    }
}

public struct SyncPullResponse: Codable, Equatable, Sendable {
    public let changes: [SyncItemRecord]
    public let latestRevision: Int64
    public let hasMore: Bool

    public init(changes: [SyncItemRecord], latestRevision: Int64, hasMore: Bool) {
        self.changes = changes
        self.latestRevision = latestRevision
        self.hasMore = hasMore
    }
}

public struct SyncHealthResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let revision: Int64
    public let itemCount: Int
    public let serverTime: String

    public init(ok: Bool, revision: Int64, itemCount: Int, serverTime: String) {
        self.ok = ok
        self.revision = revision
        self.itemCount = itemCount
        self.serverTime = serverTime
    }
}

public struct SyncBlobsCheckRequest: Codable, Equatable, Sendable {
    public let hashes: [String]
}

public struct SyncBlobsCheckResponse: Codable, Equatable, Sendable {
    public let missing: [String]
}

public struct SyncedEntityBaseline: Codable, Equatable, Sendable {
    public var revision: Int64
    public var contentHash: String
    public var deleted: Bool
    public var updatedAt: Date

    public init(revision: Int64, contentHash: String, deleted: Bool, updatedAt: Date) {
        self.revision = revision
        self.contentHash = contentHash
        self.deleted = deleted
        self.updatedAt = updatedAt
    }
}

public struct SyncStateSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var serverOrigin: String
    public var lastPulledRevision: Int64
    public var lastSyncedAt: Date?
    public var items: [String: SyncedEntityBaseline]
    public var localConfigUpdatedAt: [String: Date]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        serverOrigin: String = "",
        lastPulledRevision: Int64 = 0,
        lastSyncedAt: Date? = nil,
        items: [String: SyncedEntityBaseline] = [:],
        localConfigUpdatedAt: [String: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.serverOrigin = serverOrigin
        self.lastPulledRevision = lastPulledRevision
        self.lastSyncedAt = lastSyncedAt
        self.items = items
        self.localConfigUpdatedAt = localConfigUpdatedAt
    }
}

public enum SyncStatus: Equatable, Sendable {
    case disabled
    case unconfigured
    case idle(lastSyncedAt: Date?)
    case syncing
    case failed(String)
}

@MainActor
public final class SyncStateStore {
    public let fileURL: URL
    public var state: SyncStateSnapshot

    public init(fileURL: URL? = nil) {
        let resolved = (fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DontsTool/Sync/state.json", isDirectory: false)).standardizedFileURL
        self.fileURL = resolved
        if let data = try? Data(contentsOf: resolved),
           let decoded = try? SyncJSON.makeDecoder().decode(SyncStateSnapshot.self, from: data),
           decoded.schemaVersion == SyncStateSnapshot.currentSchemaVersion {
            state = decoded
        } else {
            state = SyncStateSnapshot()
        }
    }

    public func ensureOrigin(_ origin: String) {
        guard state.serverOrigin != origin else { return }
        state = SyncStateSnapshot(serverOrigin: origin)
    }

    public func save() throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try SyncJSON.makeEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
