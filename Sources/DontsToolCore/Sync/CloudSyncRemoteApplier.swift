import Foundation

/// Merges pulled remote sync records into local stores and resolves conflicts.
@MainActor
struct CloudSyncRemoteApplier {
    private let settings: SettingsStore
    private let websites: WebsiteShortcutStore
    private let searchEngines: SearchEngineStore
    private let notes: LocalNoteStore
    private let stateStore: SyncStateStore
    private let snapshotBuilder: CloudSyncSnapshotBuilder
    private let deviceNameProvider: () -> String

    init(
        settings: SettingsStore,
        websites: WebsiteShortcutStore,
        searchEngines: SearchEngineStore,
        notes: LocalNoteStore,
        stateStore: SyncStateStore,
        snapshotBuilder: CloudSyncSnapshotBuilder,
        deviceNameProvider: @escaping () -> String
    ) {
        self.settings = settings
        self.websites = websites
        self.searchEngines = searchEngines
        self.notes = notes
        self.stateStore = stateStore
        self.snapshotBuilder = snapshotBuilder
        self.deviceNameProvider = deviceNameProvider
    }

    func applyRemoteChange(
        _ change: SyncItemRecord,
        client: CloudSyncClient,
        performLocalWrite: @MainActor (@MainActor () throws -> Void) throws -> Void
    ) async throws -> Bool {
        let currentLocal = try snapshotBuilder.buildLocalItem(for: change.entityKey)
        let baseline = stateStore.state.items[change.entityKey]
        let localDirty = isLocallyDirty(currentLocal: currentLocal, baseline: baseline)

        // Fast convergence: local and remote already match identically.
        if let currentLocal, !change.deleted, currentLocal.contentHash == change.contentHash {
            recordBaseline(for: change, deleted: false)
            return false
        }
        if currentLocal == nil, change.deleted {
            recordBaseline(for: change, deleted: true)
            return false
        }

        switch change.entityKey {
        case let key where SyncEntityKey.parseNoteID(key) != nil:
            guard let noteID = SyncEntityKey.parseNoteID(key) else { return false }
            return try await applyRemoteNoteChange(
                change,
                noteID: noteID,
                currentLocal: currentLocal,
                baseline: baseline,
                localDirty: localDirty,
                client: client,
                performLocalWrite: performLocalWrite
            )

        case SyncEntityKey.websites:
            return try await applyRemoteWebsitesChange(
                change,
                baseline: baseline,
                localDirty: localDirty,
                client: client,
                performLocalWrite: performLocalWrite
            )

        case SyncEntityKey.searchEngines:
            return try await applyRemoteSearchEnginesChange(
                change,
                baseline: baseline,
                localDirty: localDirty,
                client: client,
                performLocalWrite: performLocalWrite
            )

        case SyncEntityKey.settings:
            return try await applyRemoteSettingsChange(
                change,
                baseline: baseline,
                localDirty: localDirty,
                client: client,
                performLocalWrite: performLocalWrite
            )

        default:
            return false
        }
    }

    private func applyRemoteNoteChange(
        _ change: SyncItemRecord,
        noteID: UUID,
        currentLocal: SyncLocalItem?,
        baseline: SyncedEntityBaseline?,
        localDirty: Bool,
        client: CloudSyncClient,
        performLocalWrite: @MainActor (@MainActor () throws -> Void) throws -> Void
    ) async throws -> Bool {
        if change.deleted {
            if localDirty, currentLocal != nil {
                // Local edited while remote deleted: preserve local edits and let push revive.
                recordBaseline(for: change, deleted: true)
                return false
            }
            try performLocalWrite {
                try notes.applySyncedDeletion(noteID)
            }
            recordBaseline(for: change, deleted: true)
            return true
        }

        let payloadData = try await resolvePayloadData(for: change, client: client)
        let remotePayload = try SyncJSON.makeDecoder().decode(SyncedNotePayload.self, from: payloadData)
        var downloadedAssets: [String: Data] = [:]
        for ref in remotePayload.assets {
            downloadedAssets[ref.relativePath] = try await client.downloadBlob(sha256: ref.sha256)
        }

        let hasUnsyncedLocalNote = (localDirty && currentLocal != nil) || (baseline == nil && currentLocal != nil)
        if hasUnsyncedLocalNote, let localSnapshot = try notes.noteSnapshot(noteID) {
            let conflictTitle = conflictCopyTitle(localSnapshot.record.title)
            try performLocalWrite {
                _ = try notes.createCopy(
                    title: conflictTitle,
                    content: localSnapshot.record.content,
                    isPinned: localSnapshot.record.isPinned,
                    assets: localSnapshot.assets
                )
            }
        }

        try performLocalWrite {
            try notes.applySyncedNote(remotePayload.record, isTrashed: remotePayload.isTrashed, assets: downloadedAssets)
        }
        recordBaseline(for: change, deleted: false)
        return true
    }

    private func applyRemoteWebsitesChange(
        _ change: SyncItemRecord,
        baseline: SyncedEntityBaseline?,
        localDirty: Bool,
        client: CloudSyncClient,
        performLocalWrite: @MainActor (@MainActor () throws -> Void) throws -> Void
    ) async throws -> Bool {
        guard !change.deleted else { return false }
        let decoded: WebsiteShortcutConfiguration
        if baseline == nil && !websites.configuration.groups.isEmpty {
            let payloadData = try await resolvePayloadData(for: change, client: client)
            let candidate = try WebsiteShortcutConfiguration.decode(String(decoding: payloadData, as: UTF8.self))
            if candidate.groups.isEmpty {
                // Never overwrite non-empty local website shortcuts with an empty initial remote snapshot.
                recordBaseline(for: change, deleted: false)
                return false
            }
            decoded = candidate
        } else {
            guard let payloadData = try await resolveConfigPayloadIfNotStale(
                change,
                baseline: baseline,
                localDirty: localDirty,
                client: client
            ) else {
                return false
            }
            decoded = try WebsiteShortcutConfiguration.decode(String(decoding: payloadData, as: UTF8.self))
        }
        try commitConfigChange(for: change) {
            try performLocalWrite {
                try websites.save(decoded)
            }
        }
        return false
    }

    private func applyRemoteSearchEnginesChange(
        _ change: SyncItemRecord,
        baseline: SyncedEntityBaseline?,
        localDirty: Bool,
        client: CloudSyncClient,
        performLocalWrite: @MainActor (@MainActor () throws -> Void) throws -> Void
    ) async throws -> Bool {
        guard let payloadData = try await resolveConfigPayloadIfNotStale(
            change,
            baseline: baseline,
            localDirty: localDirty,
            client: client
        ) else {
            return false
        }
        let decoded = try SearchEngineConfiguration.decode(String(decoding: payloadData, as: UTF8.self), reservedKeywords: [])
        let websiteKeywords = Set(websites.configuration.groups.map(\.keyword))
        let reserved = SearchEngineKeywordRules.reservedKeywords(
            current: searchEngines.configuration,
            proposed: decoded,
            websiteKeywords: websiteKeywords
        )
        try commitConfigChange(for: change) {
            try performLocalWrite {
                try searchEngines.save(decoded, reservedKeywords: reserved)
            }
        }
        return false
    }

    private func applyRemoteSettingsChange(
        _ change: SyncItemRecord,
        baseline: SyncedEntityBaseline?,
        localDirty: Bool,
        client: CloudSyncClient,
        performLocalWrite: @MainActor (@MainActor () throws -> Void) throws -> Void
    ) async throws -> Bool {
        guard let payloadData = try await resolveConfigPayloadIfNotStale(
            change,
            baseline: baseline,
            localDirty: localDirty,
            client: client
        ) else {
            return false
        }
        let decoded = try SyncJSON.makeDecoder().decode(SettingsStore.SyncedAppSettings.self, from: payloadData)
        try commitConfigChange(for: change) {
            try performLocalWrite {
                settings.applySyncedSettings(decoded)
            }
        }
        return false
    }

    private func resolveConfigPayloadIfNotStale(
        _ change: SyncItemRecord,
        baseline: SyncedEntityBaseline?,
        localDirty: Bool,
        client: CloudSyncClient
    ) async throws -> Data? {
        guard !change.deleted else { return nil }
        if localDirty {
            let localUpdatedAt = stateStore.state.localConfigUpdatedAt[change.entityKey] ?? baseline?.updatedAt ?? .distantPast
            if change.updatedAt <= localUpdatedAt {
                recordBaseline(for: change, deleted: false)
                return nil
            }
        }
        return try await resolvePayloadData(for: change, client: client)
    }

    private func commitConfigChange(for change: SyncItemRecord, write: () throws -> Void) rethrows {
        try write()
        stateStore.state.localConfigUpdatedAt.removeValue(forKey: change.entityKey)
        recordBaseline(for: change, deleted: false)
    }

    private func isLocallyDirty(currentLocal: SyncLocalItem?, baseline: SyncedEntityBaseline?) -> Bool {
        guard let baseline else { return false }
        return baseline.deleted ? currentLocal != nil : currentLocal?.contentHash != baseline.contentHash
    }

    private func recordBaseline(for change: SyncItemRecord, deleted: Bool) {
        stateStore.state.items[change.entityKey] = SyncedEntityBaseline(
            revision: change.revision,
            contentHash: change.contentHash,
            deleted: deleted,
            updatedAt: change.updatedAt
        )
    }

    private func resolvePayloadData(for item: SyncItemRecord, client: CloudSyncClient) async throws -> Data {
        if let inline = item.payload {
            return Data(inline.utf8)
        }
        if let blobHash = item.payloadBlobSha256 {
            return try await client.downloadBlob(sha256: blobHash)
        }
        throw CloudSyncError.invalidResponse
    }

    private func conflictCopyTitle(_ originalTitle: String) -> String {
        let suffix = "（冲突副本 · \(deviceNameProvider())）"
        let maxBase = max(1, 80 - suffix.count)
        return String(originalTitle.prefix(maxBase)) + suffix
    }
}
