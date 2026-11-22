import Foundation

struct SyncLocalItem: Sendable {
    let entityKey: String
    let kind: SyncEntityKind
    let updatedAt: Date
    let contentHash: String
    let payloadData: Data
    let extraBlobs: [String: Data]
}

struct SyncPendingMutation: Sendable {
    let item: SyncLocalItem
    let deleted: Bool
    let baseRevision: Int64
}

struct SyncLocalSnapshot: Sendable {
    let items: [String: SyncLocalItem]
}

/// Builds local entity snapshots, diffs them against synced baselines, and encodes push batches.
@MainActor
struct CloudSyncSnapshotBuilder {
    private let settings: SettingsStore
    private let websites: WebsiteShortcutStore
    private let searchEngines: SearchEngineStore
    private let notes: LocalNoteStore
    private let stateStore: SyncStateStore

    init(
        settings: SettingsStore,
        websites: WebsiteShortcutStore,
        searchEngines: SearchEngineStore,
        notes: LocalNoteStore,
        stateStore: SyncStateStore
    ) {
        self.settings = settings
        self.websites = websites
        self.searchEngines = searchEngines
        self.notes = notes
        self.stateStore = stateStore
    }

    func buildLocalSnapshot() throws -> SyncLocalSnapshot {
        var items: [String: SyncLocalItem] = [:]
        for key in [SyncEntityKey.websites, SyncEntityKey.searchEngines, SyncEntityKey.settings] {
            if let data = try configPayloadData(for: key) {
                items[key] = makeConfigItem(key: key, data: data)
            }
        }
        for snapshot in try notes.allNoteSnapshots() {
            let item = try makeNoteItem(snapshot)
            items[item.entityKey] = item
        }
        return SyncLocalSnapshot(items: items)
    }

    func buildLocalItem(for entityKey: String) throws -> SyncLocalItem? {
        if let data = try configPayloadData(for: entityKey) {
            return makeConfigItem(key: entityKey, data: data)
        }
        guard let id = SyncEntityKey.parseNoteID(entityKey),
              let snapshot = try notes.noteSnapshot(id) else {
            return nil
        }
        return try makeNoteItem(snapshot)
    }

    func buildPushBatch() throws -> (mutations: [SyncMutationInput], requiredBlobs: [String: Data]) {
        let localSnapshot = try buildLocalSnapshot()
        let pendingMutations = diffPendingMutations(from: localSnapshot)
        guard !pendingMutations.isEmpty else { return ([], [:]) }
        return encodeMutations(pendingMutations)
    }

    func diffPendingMutations(from localSnapshot: SyncLocalSnapshot) -> [SyncPendingMutation] {
        var pendingMutations: [SyncPendingMutation] = []

        for (key, localItem) in localSnapshot.items.sorted(by: { $0.key < $1.key }) {
            guard stateStore.state.pendingConflicts[key] == nil else { continue }
            let baseline = stateStore.state.items[key]
            if let baseline, !baseline.deleted, baseline.contentHash == localItem.contentHash {
                continue
            }
            pendingMutations.append(
                SyncPendingMutation(
                    item: localItem,
                    deleted: false,
                    baseRevision: baseline?.revision ?? 0
                )
            )
        }

        // Emit deletion tombstones only for notes; configuration entities always have a live document.
        for (key, baseline) in stateStore.state.items.sorted(by: { $0.key < $1.key }) where !baseline.deleted {
            guard stateStore.state.pendingConflicts[key] == nil else { continue }
            guard localSnapshot.items[key] == nil, SyncEntityKey.parseNoteID(key) != nil else { continue }
            let deleteHash = SyncDigest.sha256Hex("deleted:\(key)")
            pendingMutations.append(
                SyncPendingMutation(
                    item: SyncLocalItem(
                        entityKey: key,
                        kind: .note,
                        updatedAt: Date(),
                        contentHash: deleteHash,
                        payloadData: Data(),
                        extraBlobs: [:]
                    ),
                    deleted: true,
                    baseRevision: baseline.revision
                )
            )
        }

        return pendingMutations
    }

    func encodeMutations(
        _ pendingMutations: [SyncPendingMutation]
    ) -> (mutations: [SyncMutationInput], requiredBlobs: [String: Data]) {
        var requiredBlobs: [String: Data] = [:]
        var wireMutations: [SyncMutationInput] = []

        for pending in pendingMutations {
            if pending.deleted {
                wireMutations.append(
                    SyncMutationInput(
                        entityKey: pending.item.entityKey,
                        kind: pending.item.kind,
                        deleted: true,
                        updatedAt: pending.item.updatedAt,
                        contentHash: pending.item.contentHash,
                        baseRevision: pending.baseRevision
                    )
                )
                continue
            }

            for (hash, blobData) in pending.item.extraBlobs {
                requiredBlobs[hash] = blobData
            }
            let payloadBytes = pending.item.payloadData
            if payloadBytes.count > CloudSyncClient.inlinePayloadLimit {
                let payloadHash = SyncDigest.sha256Hex(payloadBytes)
                requiredBlobs[payloadHash] = payloadBytes
                wireMutations.append(
                    SyncMutationInput(
                        entityKey: pending.item.entityKey,
                        kind: pending.item.kind,
                        deleted: false,
                        updatedAt: pending.item.updatedAt,
                        contentHash: pending.item.contentHash,
                        baseRevision: pending.baseRevision,
                        payloadBlobSha256: payloadHash
                    )
                )
            } else {
                wireMutations.append(
                    SyncMutationInput(
                        entityKey: pending.item.entityKey,
                        kind: pending.item.kind,
                        deleted: false,
                        updatedAt: pending.item.updatedAt,
                        contentHash: pending.item.contentHash,
                        baseRevision: pending.baseRevision,
                        payload: String(decoding: payloadBytes, as: UTF8.self)
                    )
                )
            }
        }

        return (wireMutations, requiredBlobs)
    }

    func makeConfigItem(key: String, data: Data) -> SyncLocalItem {
        let updatedAt = stateStore.state.localConfigUpdatedAt[key]
            ?? stateStore.state.items[key]?.updatedAt
            ?? .distantPast
        return SyncLocalItem(
            entityKey: key,
            kind: .config,
            updatedAt: updatedAt,
            contentHash: SyncDigest.sha256Hex(data),
            payloadData: data,
            extraBlobs: [:]
        )
    }

    func makeNoteItem(_ snapshot: NoteSyncSnapshot) throws -> SyncLocalItem {
        var assetRefs: [SyncedNoteAssetRef] = []
        var extraBlobs: [String: Data] = [:]
        for (relativePath, data) in snapshot.assets.sorted(by: { $0.key < $1.key }) {
            let hash = SyncDigest.sha256Hex(data)
            assetRefs.append(SyncedNoteAssetRef(relativePath: relativePath, sha256: hash))
            extraBlobs[hash] = data
        }
        let payload = SyncedNotePayload(record: snapshot.record, isTrashed: snapshot.isTrashed, assets: assetRefs)
        let data = try SyncJSON.makeEncoder().encode(payload)
        return SyncLocalItem(
            entityKey: SyncEntityKey.note(snapshot.record.id),
            kind: .note,
            updatedAt: snapshot.record.updatedAt,
            contentHash: SyncDigest.sha256Hex(data),
            payloadData: data,
            extraBlobs: extraBlobs
        )
    }

    private func configPayloadData(for entityKey: String) throws -> Data? {
        switch entityKey {
        case SyncEntityKey.websites:
            return Data(try websites.configuration.json().utf8)
        case SyncEntityKey.searchEngines:
            return Data(try searchEngines.configuration.json().utf8)
        case SyncEntityKey.settings:
            let encoded = try SyncJSON.makeEncoder().encode(settings.exportSyncedSettings())
            return SyncConfigMerger.injectUnknownSettingsFields(
                stateStore.state.preservedUnknownSettingsJSON,
                into: encoded
            )
        default:
            return nil
        }
    }
}
