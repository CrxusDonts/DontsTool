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
    public let baseRevision: Int64?
    public let payload: String?
    public let payloadBlobSha256: String?

    public init(
        entityKey: String,
        kind: SyncEntityKind,
        deleted: Bool,
        updatedAt: Date,
        contentHash: String,
        baseRevision: Int64? = nil,
        payload: String? = nil,
        payloadBlobSha256: String? = nil
    ) {
        self.entityKey = entityKey
        self.kind = kind
        self.deleted = deleted
        self.updatedAt = updatedAt
        self.contentHash = contentHash
        self.baseRevision = baseRevision
        self.payload = payload
        self.payloadBlobSha256 = payloadBlobSha256
    }
}

public struct SyncRevisionConflict: Codable, Equatable, Sendable {
    public let entityKey: String
    public let expectedRevision: Int64
    public let currentRevision: Int64

    public init(entityKey: String, expectedRevision: Int64, currentRevision: Int64) {
        self.entityKey = entityKey
        self.expectedRevision = expectedRevision
        self.currentRevision = currentRevision
    }
}

public struct SyncConfigConflict: Codable, Equatable, Identifiable, Sendable {
    public enum Reason: String, Codable, Equatable, Sendable {
        case concurrentModification
        case initialDivergence
        case remoteDowngradeGuard
    }

    public var id: String { entityKey }
    public let entityKey: String
    public let reason: Reason
    public let localJSON: String
    public let remoteJSON: String
    public let localUpdatedAt: Date?
    public let remoteRevision: Int64
    public let remoteUpdatedAt: Date
    public let remoteContentHash: String
    public let remoteDeviceId: String
    public let detectedAt: Date

    public init(
        entityKey: String,
        reason: Reason,
        localJSON: String,
        remoteJSON: String,
        localUpdatedAt: Date?,
        remoteRevision: Int64,
        remoteUpdatedAt: Date,
        remoteContentHash: String,
        remoteDeviceId: String,
        detectedAt: Date = Date()
    ) {
        self.entityKey = entityKey
        self.reason = reason
        self.localJSON = localJSON
        self.remoteJSON = remoteJSON
        self.localUpdatedAt = localUpdatedAt
        self.remoteRevision = remoteRevision
        self.remoteUpdatedAt = remoteUpdatedAt
        self.remoteContentHash = remoteContentHash
        self.remoteDeviceId = remoteDeviceId
        self.detectedAt = detectedAt
    }

    public var displayTitle: String {
        switch entityKey {
        case SyncEntityKey.settings: "常规与模型设置"
        case SyncEntityKey.searchEngines: "搜索引擎"
        case SyncEntityKey.websites: "网址快捷入口"
        default: entityKey
        }
    }

    public var reasonSummary: String {
        switch reason {
        case .concurrentModification:
            "本机和云端在同步前都修改过此配置，为避免互相覆盖已暂停自动合并"
        case .initialDivergence:
            "首次接入时本机已有自定义配置，且与云端版本不一致"
        case .remoteDowngradeGuard:
            "拦截到云端发来较旧时间或缺少模型配置字段的快照，疑似旧版本覆盖"
        }
    }
}

public enum SyncConflictResolution: Equatable, Sendable {
    case keepLocal
    case useRemote
    case useMergedJSON(String)
}

public enum SyncFieldChoice: String, CaseIterable, Equatable, Sendable {
    case local
    case remote
}

public struct SyncConfigFieldDiff: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public let displayName: String
    public let kind: JSONDifference.Kind
    public let localPreview: String
    public let remotePreview: String

    public init(
        key: String,
        displayName: String,
        kind: JSONDifference.Kind,
        localPreview: String,
        remotePreview: String
    ) {
        self.key = key
        self.displayName = displayName
        self.kind = kind
        self.localPreview = localPreview
        self.remotePreview = remotePreview
    }
}

public struct SyncConfigHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let entityKey: String
    public let savedAt: Date
    public let reason: String
    public let json: String

    public init(
        id: String = UUID().uuidString,
        entityKey: String,
        savedAt: Date = Date(),
        reason: String,
        json: String
    ) {
        self.id = id
        self.entityKey = entityKey
        self.savedAt = savedAt
        self.reason = reason
        self.json = json
    }

    public var displayTitle: String {
        switch entityKey {
        case SyncEntityKey.settings: "常规与模型设置"
        case SyncEntityKey.searchEngines: "搜索引擎"
        case SyncEntityKey.websites: "网址快捷入口"
        default: entityKey
        }
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
    public let itemRevisions: [String: Int64]?

    public init(revision: Int64, appliedKeys: [String], itemRevisions: [String: Int64]? = nil) {
        self.revision = revision
        self.appliedKeys = appliedKeys
        self.itemRevisions = itemRevisions
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
    public var knownRemoteBlobHashes: Set<String>
    public var pendingConflicts: [String: SyncConfigConflict]
    public var preservedUnknownSettingsJSON: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case serverOrigin
        case lastPulledRevision
        case lastSyncedAt
        case items
        case localConfigUpdatedAt
        case knownRemoteBlobHashes
        case pendingConflicts
        case preservedUnknownSettingsJSON
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        serverOrigin: String = "",
        lastPulledRevision: Int64 = 0,
        lastSyncedAt: Date? = nil,
        items: [String: SyncedEntityBaseline] = [:],
        localConfigUpdatedAt: [String: Date] = [:],
        knownRemoteBlobHashes: Set<String> = [],
        pendingConflicts: [String: SyncConfigConflict] = [:],
        preservedUnknownSettingsJSON: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.serverOrigin = serverOrigin
        self.lastPulledRevision = lastPulledRevision
        self.lastSyncedAt = lastSyncedAt
        self.items = items
        self.localConfigUpdatedAt = localConfigUpdatedAt
        self.knownRemoteBlobHashes = knownRemoteBlobHashes
        self.pendingConflicts = pendingConflicts
        self.preservedUnknownSettingsJSON = preservedUnknownSettingsJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        serverOrigin = try container.decode(String.self, forKey: .serverOrigin)
        lastPulledRevision = try container.decode(Int64.self, forKey: .lastPulledRevision)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        items = try container.decode([String: SyncedEntityBaseline].self, forKey: .items)
        localConfigUpdatedAt = try container.decode([String: Date].self, forKey: .localConfigUpdatedAt)
        knownRemoteBlobHashes = try container.decodeIfPresent(Set<String>.self, forKey: .knownRemoteBlobHashes) ?? []
        pendingConflicts = try container.decodeIfPresent([String: SyncConfigConflict].self, forKey: .pendingConflicts) ?? [:]
        preservedUnknownSettingsJSON = try container.decodeIfPresent(String.self, forKey: .preservedUnknownSettingsJSON)
    }
}

public enum SyncStatus: Equatable, Sendable {
    case disabled
    case unconfigured
    case idle(lastSyncedAt: Date?)
    case syncing
    case needsResolution(conflictCount: Int, lastSyncedAt: Date?)
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
