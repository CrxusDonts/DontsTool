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
    private let historyStore: SyncConfigHistoryStore
    private let deviceNameProvider: () -> String

    init(
        settings: SettingsStore,
        websites: WebsiteShortcutStore,
        searchEngines: SearchEngineStore,
        notes: LocalNoteStore,
        stateStore: SyncStateStore,
        snapshotBuilder: CloudSyncSnapshotBuilder,
        historyStore: SyncConfigHistoryStore,
        deviceNameProvider: @escaping () -> String
    ) {
        self.settings = settings
        self.websites = websites
        self.searchEngines = searchEngines
        self.notes = notes
        self.stateStore = stateStore
        self.snapshotBuilder = snapshotBuilder
        self.historyStore = historyStore
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
            stateStore.state.pendingConflicts.removeValue(forKey: change.entityKey)
            recordBaseline(for: change, deleted: false)
            return false
        }
        if currentLocal == nil, change.deleted {
            stateStore.state.pendingConflicts.removeValue(forKey: change.entityKey)
            recordBaseline(for: change, deleted: true)
            return false
        }

        if let baseline,
           stateStore.state.pendingConflicts[change.entityKey] == nil,
           baseline.deleted == change.deleted,
           (baseline.contentHash == change.contentHash || change.revision == baseline.revision) {
            stateStore.state.items[change.entityKey] = SyncedEntityBaseline(
                revision: change.revision,
                contentHash: baseline.contentHash,
                deleted: change.deleted,
                updatedAt: max(baseline.updatedAt, change.updatedAt)
            )
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

        case SyncEntityKey.websites, SyncEntityKey.searchEngines, SyncEntityKey.settings:
            return try await applyRemoteConfigChange(
                change,
                currentLocal: currentLocal,
                baseline: baseline,
                localDirty: localDirty,
                client: client,
                performLocalWrite: performLocalWrite
            )

        default:
            return false
        }
    }

    func currentConfigJSON(for entityKey: String) -> String {
        guard let item = try? snapshotBuilder.buildLocalItem(for: entityKey) else {
            return ""
        }
        return SyncConfigMerger.prettyJSON(from: item.payloadData)
    }

    func currentConfigHash(for entityKey: String) -> String? {
        try? snapshotBuilder.buildLocalItem(for: entityKey)?.contentHash
    }

    func validateConfigJSON(_ json: String, for entityKey: String) -> String? {
        do {
            switch entityKey {
            case SyncEntityKey.websites:
                _ = try WebsiteShortcutConfiguration.decode(json)
            case SyncEntityKey.searchEngines:
                let decoded = try SearchEngineConfiguration.decode(json, reservedKeywords: [])
                let websiteKeywords = Set(websites.configuration.groups.map(\.keyword))
                let reserved = SearchEngineKeywordRules.reservedKeywords(
                    current: searchEngines.configuration,
                    proposed: decoded,
                    websiteKeywords: websiteKeywords
                )
                _ = try decoded.validated(reservedKeywords: reserved)
            case SyncEntityKey.settings:
                _ = try SyncJSON.makeDecoder().decode(SettingsStore.SyncedAppSettings.self, from: Data(json.utf8))
            default:
                return "不支持的配置实体：\(entityKey)"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func applyConfigJSON(
        _ json: String,
        for entityKey: String,
        performLocalWrite: @MainActor (@MainActor () throws -> Void) throws -> Void
    ) throws {
        try applyConfigPayloadData(Data(json.utf8), for: entityKey, performLocalWrite: performLocalWrite)
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
            if let existingData = currentLocal?.extraBlobs[ref.sha256] {
                downloadedAssets[ref.relativePath] = existingData
            } else {
                downloadedAssets[ref.relativePath] = try await client.downloadBlob(sha256: ref.sha256)
            }
            stateStore.state.knownRemoteBlobHashes.insert(ref.sha256)
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
        let localHash = (try? snapshotBuilder.buildLocalItem(for: change.entityKey))?.contentHash ?? change.contentHash
        recordBaseline(for: change, deleted: false, contentHashOverride: localHash)
        return true
    }

    private func applyRemoteConfigChange(
        _ change: SyncItemRecord,
        currentLocal: SyncLocalItem?,
        baseline: SyncedEntityBaseline?,
        localDirty: Bool,
        client: CloudSyncClient,
        performLocalWrite: @MainActor (@MainActor () throws -> Void) throws -> Void
    ) async throws -> Bool {
        guard !change.deleted else { return false }
        let payloadData = try await resolvePayloadData(for: change, client: client)

        if change.entityKey == SyncEntityKey.websites, baseline == nil, !websites.configuration.groups.isEmpty {
            let candidate = try WebsiteShortcutConfiguration.decode(String(decoding: payloadData, as: UTF8.self))
            if candidate.groups.isEmpty {
                // Never overwrite non-empty local website shortcuts with an empty initial remote snapshot.
                recordBaseline(for: change, deleted: false)
                return false
            }
        }

        // Validate remote config payload before raising a conflict or overwriting local stores.
        try validateConfigPayloadData(payloadData, for: change.entityKey)

        let conflictReason: SyncConfigConflict.Reason?
        if let existingConflict = stateStore.state.pendingConflicts[change.entityKey] {
            conflictReason = existingConflict.reason
        } else if localDirty {
            conflictReason = .concurrentModification
        } else if baseline == nil && isCustomizedLocalConfig(change.entityKey) {
            conflictReason = .initialDivergence
        } else if let baseline, isSuspiciousRemoteDowngrade(
            entityKey: change.entityKey,
            change: change,
            baseline: baseline,
            payloadData: payloadData
        ) {
            conflictReason = .remoteDowngradeGuard
        } else {
            conflictReason = nil
        }

        if let conflictReason {
            let localJSON = currentLocal.map { SyncConfigMerger.prettyJSON(from: $0.payloadData) }
                ?? currentConfigJSON(for: change.entityKey)
            let remoteJSON = SyncConfigMerger.prettyJSON(from: payloadData)
            stateStore.state.pendingConflicts[change.entityKey] = SyncConfigConflict(
                entityKey: change.entityKey,
                reason: conflictReason,
                localJSON: localJSON,
                remoteJSON: remoteJSON,
                localUpdatedAt: stateStore.state.localConfigUpdatedAt[change.entityKey] ?? baseline?.updatedAt,
                remoteRevision: change.revision,
                remoteUpdatedAt: change.updatedAt,
                remoteContentHash: change.contentHash,
                remoteDeviceId: change.deviceId
            )
            return false
        }

        if let localData = currentLocal?.payloadData {
            historyStore.recordSnapshot(
                entityKey: change.entityKey,
                json: SyncConfigMerger.prettyJSON(from: localData),
                reason: "远端同步覆盖前自动备份"
            )
        }

        try commitConfigChange(for: change) {
            try applyConfigPayloadData(payloadData, for: change.entityKey, performLocalWrite: performLocalWrite)
        }
        return false
    }

    private func validateConfigPayloadData(_ payloadData: Data, for entityKey: String) throws {
        switch entityKey {
        case SyncEntityKey.websites:
            _ = try WebsiteShortcutConfiguration.decode(String(decoding: payloadData, as: UTF8.self))
        case SyncEntityKey.searchEngines:
            _ = try SearchEngineConfiguration.decode(String(decoding: payloadData, as: UTF8.self), reservedKeywords: [])
        case SyncEntityKey.settings:
            _ = try SyncJSON.makeDecoder().decode(SettingsStore.SyncedAppSettings.self, from: payloadData)
        default:
            break
        }
    }

    private func applyConfigPayloadData(
        _ payloadData: Data,
        for entityKey: String,
        performLocalWrite: @MainActor (@MainActor () throws -> Void) throws -> Void
    ) throws {
        switch entityKey {
        case SyncEntityKey.websites:
            let decoded = try WebsiteShortcutConfiguration.decode(String(decoding: payloadData, as: UTF8.self))
            try performLocalWrite {
                try websites.save(decoded)
            }
        case SyncEntityKey.searchEngines:
            let decoded = try SearchEngineConfiguration.decode(String(decoding: payloadData, as: UTF8.self), reservedKeywords: [])
            let websiteKeywords = Set(websites.configuration.groups.map(\.keyword))
            let reserved = SearchEngineKeywordRules.reservedKeywords(
                current: searchEngines.configuration,
                proposed: decoded,
                websiteKeywords: websiteKeywords
            )
            try performLocalWrite {
                try searchEngines.save(decoded, reservedKeywords: reserved)
            }
        case SyncEntityKey.settings:
            let decoded = try SyncJSON.makeDecoder().decode(SettingsStore.SyncedAppSettings.self, from: payloadData)
            stateStore.state.preservedUnknownSettingsJSON = SyncConfigMerger.extractUnknownSettingsFields(from: payloadData)
            try performLocalWrite {
                settings.applySyncedSettings(decoded)
            }
        default:
            break
        }
    }

    private func isCustomizedLocalConfig(_ entityKey: String) -> Bool {
        switch entityKey {
        case SyncEntityKey.websites:
            return !websites.configuration.groups.isEmpty
        case SyncEntityKey.searchEngines:
            return searchEngines.configuration != .builtIn
        case SyncEntityKey.settings:
            return !settings.aiModelProfiles.isEmpty
                || !settings.aiConsumerModelBindings.isEmpty
                || !settings.translationAPIBaseURL.isEmpty
                || !settings.translationAPIModel.isEmpty
                || !settings.preferredTerminalBundleID.isEmpty
                || settings.hotKey != .optionSpace
                || settings.selectionTranslationEnabled
                || settings.applicationSortOrder != .recent
        default:
            return false
        }
    }

    private func isSuspiciousRemoteDowngrade(
        entityKey: String,
        change: SyncItemRecord,
        baseline: SyncedEntityBaseline,
        payloadData: Data
    ) -> Bool {
        if change.updatedAt < baseline.updatedAt {
            return true
        }
        switch entityKey {
        case SyncEntityKey.settings:
            guard let decoded = try? SyncJSON.makeDecoder().decode(SettingsStore.SyncedAppSettings.self, from: payloadData) else {
                return false
            }
            if !settings.aiModelProfiles.isEmpty
                && (decoded.aiModelProfiles == nil || decoded.aiModelProfiles?.isEmpty == true) {
                return true
            }
            if !settings.aiConsumerModelBindings.isEmpty && decoded.aiConsumerModelBindings == nil {
                return true
            }
            return false
        case SyncEntityKey.websites:
            guard let decoded = try? WebsiteShortcutConfiguration.decode(String(decoding: payloadData, as: UTF8.self)) else {
                return false
            }
            return !websites.configuration.groups.isEmpty && decoded.groups.isEmpty
        default:
            return false
        }
    }

    private func commitConfigChange(for change: SyncItemRecord, write: () throws -> Void) throws {
        try write()
        stateStore.state.localConfigUpdatedAt.removeValue(forKey: change.entityKey)
        let localHash = (try? snapshotBuilder.buildLocalItem(for: change.entityKey))?.contentHash ?? change.contentHash
        recordBaseline(for: change, deleted: false, contentHashOverride: localHash)
    }

    private func isLocallyDirty(currentLocal: SyncLocalItem?, baseline: SyncedEntityBaseline?) -> Bool {
        guard let baseline else { return false }
        return baseline.deleted ? currentLocal != nil : currentLocal?.contentHash != baseline.contentHash
    }

    private func recordBaseline(for change: SyncItemRecord, deleted: Bool, contentHashOverride: String? = nil) {
        stateStore.state.items[change.entityKey] = SyncedEntityBaseline(
            revision: change.revision,
            contentHash: contentHashOverride ?? change.contentHash,
            deleted: deleted,
            updatedAt: change.updatedAt
        )
    }

    private func resolvePayloadData(for item: SyncItemRecord, client: CloudSyncClient) async throws -> Data {
        if let inline = item.payload {
            return Data(inline.utf8)
        }
        if let blobHash = item.payloadBlobSha256 {
            let data = try await client.downloadBlob(sha256: blobHash)
            stateStore.state.knownRemoteBlobHashes.insert(blobHash)
            return data
        }
        throw CloudSyncError.invalidResponse
    }

    private func conflictCopyTitle(_ originalTitle: String) -> String {
        let suffix = "（冲突副本 · \(deviceNameProvider())）"
        let maxBase = max(1, 80 - suffix.count)
        return String(originalTitle.prefix(maxBase)) + suffix
    }
}
