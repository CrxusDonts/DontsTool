import Combine
import Foundation

@MainActor
public final class CloudSyncCoordinator: ObservableObject {
    @Published public private(set) var status: SyncStatus = .disabled
    @Published public private(set) var isRealtimeConnected = false

    public var prepareNotesForSync: @MainActor () async -> Void = {}
    public var didApplyRemoteNotes: @MainActor () -> Void = {}

    private let settings: SettingsStore
    private let websites: WebsiteShortcutStore
    private let searchEngines: SearchEngineStore
    private let notes: LocalNoteStore
    private let secrets: any SecretStoring
    private let httpClient: any HTTPRequesting
    private let stateStore: SyncStateStore
    private let realtimeClientFactory: (@Sendable (CloudSyncOrigin, String) -> any SyncRealtimeListening)?
    private let debounceDuration: Duration
    private let snapshotBuilder: CloudSyncSnapshotBuilder
    private let remoteApplier: CloudSyncRemoteApplier

    private enum SyncTrigger {
        case full
        case localChange
    }

    private var subscriptions: Set<AnyCancellable> = []
    private var debounceTask: Task<Void, Never>?
    private var realtimeClient: (any SyncRealtimeListening)?
    private var activeOriginString: String?
    private var activeToken: String?
    private var isSyncing = false
    private var pendingSyncTrigger: SyncTrigger?
    private var highestNotifiedRemoteRevision: Int64 = 0
    private var hasPulledInActiveRealtimeSession = false
    private var isApplyingRemote = false
    private var isStarted = false

    public init(
        settings: SettingsStore,
        websites: WebsiteShortcutStore,
        searchEngines: SearchEngineStore,
        notes: LocalNoteStore,
        secrets: any SecretStoring,
        httpClient: any HTTPRequesting = URLSessionHTTPClient(),
        stateStore: SyncStateStore = SyncStateStore(),
        realtimeClientFactory: (@Sendable (CloudSyncOrigin, String) -> any SyncRealtimeListening)? = {
            URLSessionSyncRealtimeClient(origin: $0, token: $1)
        },
        deviceNameProvider: @escaping () -> String = { Host.current().localizedName ?? "Mac" },
        debounceDuration: Duration = .milliseconds(5000)
    ) {
        self.settings = settings
        self.websites = websites
        self.searchEngines = searchEngines
        self.notes = notes
        self.secrets = secrets
        self.httpClient = httpClient
        self.stateStore = stateStore
        self.realtimeClientFactory = realtimeClientFactory
        self.debounceDuration = debounceDuration
        let builder = CloudSyncSnapshotBuilder(
            settings: settings, websites: websites, searchEngines: searchEngines, notes: notes, stateStore: stateStore
        )
        self.snapshotBuilder = builder
        self.remoteApplier = CloudSyncRemoteApplier(
            settings: settings, websites: websites, searchEngines: searchEngines, notes: notes,
            stateStore: stateStore, snapshotBuilder: builder, deviceNameProvider: deviceNameProvider
        )
        refreshIdleStatus()
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        observeStores()
        reloadConfiguration(triggerSync: true)
    }

    public func stop() {
        isStarted = false
        debounceTask?.cancel()
        debounceTask = nil
        stopRealtime()
        subscriptions.removeAll()
    }

    public func reloadConfiguration(triggerSync: Bool = true) {
        guard let credentials = resolvedCredentials() else {
            stopRealtime()
            status = settings.cloudSyncEnabled ? .unconfigured : .disabled
            return
        }
        startRealtimeIfNeeded(origin: credentials.origin, token: credentials.token)
        if !isSyncing {
            status = .idle(lastSyncedAt: stateStore.state.lastSyncedAt)
        }
        if triggerSync {
            Task { [weak self] in
                await self?.syncNow()
            }
        }
    }

    public func testConnection() async throws -> SyncHealthResponse {
        let credentials = try validatedCredentials()
        let client = CloudSyncClient(origin: credentials.origin, token: credentials.token, httpClient: httpClient)
        return try await client.health()
    }

    @discardableResult
    public func syncNow() async -> Bool {
        await sync(trigger: .full)
    }

    @discardableResult
    private func sync(trigger: SyncTrigger) async -> Bool {
        if isSyncing {
            if pendingSyncTrigger != .full {
                pendingSyncTrigger = trigger
            }
            return true
        }
        guard let credentials = resolvedCredentials() else {
            stopRealtime()
            status = settings.cloudSyncEnabled ? .unconfigured : .disabled
            return false
        }

        isSyncing = true
        status = .syncing
        defer { isSyncing = false }

        var overallSuccess = true
        var currentTrigger: SyncTrigger? = trigger
        while let activeTrigger = currentTrigger {
            pendingSyncTrigger = nil
            do {
                try await performSingleSyncPass(
                    origin: credentials.origin,
                    token: credentials.token,
                    trigger: activeTrigger
                )
                status = .idle(lastSyncedAt: stateStore.state.lastSyncedAt)
                if highestNotifiedRemoteRevision > stateStore.state.lastPulledRevision {
                    currentTrigger = .full
                } else {
                    currentTrigger = pendingSyncTrigger
                }
            } catch {
                overallSuccess = false
                status = .failed(error.localizedDescription)
                pendingSyncTrigger = nil
                break
            }
        }

        return overallSuccess
    }

    private func performSingleSyncPass(origin: CloudSyncOrigin, token: String, trigger: SyncTrigger) async throws {
        await prepareNotesForSync()
        let client = CloudSyncClient(origin: origin, token: token, httpClient: httpClient)
        let previousOrigin = stateStore.state.serverOrigin
        stateStore.ensureOrigin(origin.originString)
        if previousOrigin != origin.originString {
            highestNotifiedRemoteRevision = 0
            hasPulledInActiveRealtimeSession = false
        }

        // 1. Pull remote revisions first unless an active realtime session is already caught up.
        let canSkipInitialPull = trigger == .localChange
            && isRealtimeConnected
            && hasPulledInActiveRealtimeSession
            && highestNotifiedRemoteRevision <= stateStore.state.lastPulledRevision

        if !canSkipInitialPull {
            let appliedAnyRemoteNote = try await pullRemoteChanges(with: client)
            try stateStore.save()
            if appliedAnyRemoteNote {
                didApplyRemoteNotes()
            }
            if isRealtimeConnected {
                hasPulledInActiveRealtimeSession = true
            }
        }

        // 2. Diff local state against synced baselines and push local mutations.
        try await pushLocalMutations(with: client)
    }

    private func pullRemoteChanges(with client: CloudSyncClient) async throws -> Bool {
        var appliedAnyRemoteNote = false
        var hasMore = true
        while hasMore {
            let page = try await client.pull(since: stateStore.state.lastPulledRevision, limit: 100)
            for change in page.changes {
                let didChangeNotes = try await remoteApplier.applyRemoteChange(change, client: client) { operation in
                    try self.performLocalWrite(operation)
                }
                if didChangeNotes {
                    appliedAnyRemoteNote = true
                }
                stateStore.state.lastPulledRevision = max(stateStore.state.lastPulledRevision, change.revision)
            }
            stateStore.state.lastPulledRevision = max(stateStore.state.lastPulledRevision, page.latestRevision)
            hasMore = page.hasMore
        }
        return appliedAnyRemoteNote
    }

    private func pushLocalMutations(with client: CloudSyncClient) async throws {
        let (wireMutations, requiredBlobs) = try snapshotBuilder.buildPushBatch()
        guard !wireMutations.isEmpty else {
            stateStore.state.lastSyncedAt = Date()
            try stateStore.save()
            return
        }

        try await ensureBlobsUploaded(requiredBlobs, client: client)

        let batchSize = 100
        var contiguousRevision = stateStore.state.lastPulledRevision
        var detectedRemoteGap = false
        var didRetryMissingBlobs = false

        for start in stride(from: 0, to: wireMutations.count, by: batchSize) {
            let end = min(start + batchSize, wireMutations.count)
            let batch = Array(wireMutations[start..<end])
            let request = SyncPushRequest(deviceId: settings.cloudSyncDeviceID, mutations: batch)
            let response: SyncPushResponse
            do {
                response = try await client.push(request)
            } catch CloudSyncError.conflict(_) where !requiredBlobs.isEmpty && !didRetryMissingBlobs {
                didRetryMissingBlobs = true
                stateStore.state.knownRemoteBlobHashes.removeAll()
                try await ensureBlobsUploaded(requiredBlobs, client: client, forceCheckAll: true)
                response = try await client.push(request)
            }

            let appliedCount = Int64(response.appliedKeys.count)
            if !detectedRemoteGap {
                if response.revision == contiguousRevision + appliedCount {
                    contiguousRevision = response.revision
                } else if response.revision > contiguousRevision + appliedCount {
                    detectedRemoteGap = true
                    highestNotifiedRemoteRevision = max(highestNotifiedRemoteRevision, response.revision)
                }
            } else {
                highestNotifiedRemoteRevision = max(highestNotifiedRemoteRevision, response.revision)
            }

            for mutation in batch {
                stateStore.state.items[mutation.entityKey] = SyncedEntityBaseline(
                    revision: response.revision,
                    contentHash: mutation.contentHash,
                    deleted: mutation.deleted,
                    updatedAt: mutation.updatedAt
                )
                stateStore.state.localConfigUpdatedAt.removeValue(forKey: mutation.entityKey)
            }
        }

        stateStore.state.lastPulledRevision = max(stateStore.state.lastPulledRevision, contiguousRevision)
        stateStore.state.lastSyncedAt = Date()
        try stateStore.save()
    }

    private func ensureBlobsUploaded(
        _ requiredBlobs: [String: Data],
        client: CloudSyncClient,
        forceCheckAll: Bool = false
    ) async throws {
        let candidateHashes = forceCheckAll
            ? Array(requiredBlobs.keys).sorted()
            : requiredBlobs.keys.filter { !stateStore.state.knownRemoteBlobHashes.contains($0) }.sorted()
        guard !candidateHashes.isEmpty else { return }

        for start in stride(from: 0, to: candidateHashes.count, by: 500) {
            let end = min(start + 500, candidateHashes.count)
            let chunk = Array(candidateHashes[start..<end])
            let missing = try await client.checkMissingBlobs(chunk)
            let missingSet = Set(missing)
            for hash in chunk where !missingSet.contains(hash) {
                stateStore.state.knownRemoteBlobHashes.insert(hash)
            }
            for hash in missing {
                guard let data = requiredBlobs[hash] else { continue }
                try await client.uploadBlob(sha256: hash, data: data)
                stateStore.state.knownRemoteBlobHashes.insert(hash)
            }
        }
    }

    private func performLocalWrite(_ operation: @MainActor () throws -> Void) throws {
        let wasApplyingRemote = isApplyingRemote
        isApplyingRemote = true
        defer { isApplyingRemote = wasApplyingRemote }
        try operation()
    }

    private func observeStores() {
        notes.$notes.dropFirst().sink { [weak self] _ in self?.scheduleLocalChangeSync() }.store(in: &subscriptions)
        notes.$trashedNotes.dropFirst().sink { [weak self] _ in self?.scheduleLocalChangeSync() }.store(in: &subscriptions)
        websites.$configuration.dropFirst().sink { [weak self] _ in
            self?.recordConfigChange(SyncEntityKey.websites)
        }.store(in: &subscriptions)
        searchEngines.$configuration.dropFirst().sink { [weak self] _ in
            self?.recordConfigChange(SyncEntityKey.searchEngines)
        }.store(in: &subscriptions)

        let syncableSettingsChanges: [AnyPublisher<Void, Never>] = [
            settings.$hotKey.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$applicationSortOrder.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$enabledProviderIDs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$fileSearchEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$translationTarget.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$translationAPIBaseURL.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$translationAPIModel.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$aiAPIFormat.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$selectionHoldDelay.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$selectionTranslationEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$preferredTerminalBundleID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$aiModelProfiles.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$defaultAIModelProfileID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$translationAIModelProfileID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$quickAIAIModelProfileID.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(syncableSettingsChanges)
            .sink { [weak self] _ in self?.recordConfigChange(SyncEntityKey.settings) }
            .store(in: &subscriptions)

        settings.$cloudSyncEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reloadConfiguration(triggerSync: true) }
        }.store(in: &subscriptions)

        settings.$cloudSyncServerURL.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reloadConfiguration(triggerSync: false) }
        }.store(in: &subscriptions)
    }

    private func recordConfigChange(_ key: String) {
        guard !isApplyingRemote else { return }
        stateStore.state.localConfigUpdatedAt[key] = Date()
        scheduleLocalChangeSync()
    }

    private func scheduleLocalChangeSync() {
        guard !isApplyingRemote, resolvedCredentials() != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.debounceDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.sync(trigger: .localChange)
        }
    }

    private func startRealtimeIfNeeded(origin: CloudSyncOrigin, token: String) {
        guard let realtimeClientFactory else { return }
        if activeOriginString == origin.originString && activeToken == token && realtimeClient != nil {
            return
        }
        stopRealtime()
        activeOriginString = origin.originString
        activeToken = token
        let client = realtimeClientFactory(origin, token)
        realtimeClient = client
        let currentDeviceID = settings.cloudSyncDeviceID
        client.start(
            onSyncEvent: { [weak self] revision, sourceDeviceID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Ignore our own device's push broadcast so WS echo arriving before the
                    // HTTP push response never schedules a redundant follow-up pull.
                    if !sourceDeviceID.isEmpty, sourceDeviceID == currentDeviceID {
                        return
                    }
                    self.highestNotifiedRemoteRevision = max(self.highestNotifiedRemoteRevision, revision)
                    guard revision > self.stateStore.state.lastPulledRevision else {
                        return
                    }
                    if !self.isSyncing {
                        await self.sync(trigger: .full)
                    }
                }
            },
            onConnectionChanged: { [weak self] connected in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRealtimeConnected = connected
                    if !connected {
                        self.hasPulledInActiveRealtimeSession = false
                    }
                }
            }
        )
    }

    private func stopRealtime() {
        realtimeClient?.stop()
        realtimeClient = nil
        activeOriginString = nil
        activeToken = nil
        isRealtimeConnected = false
        hasPulledInActiveRealtimeSession = false
        highestNotifiedRemoteRevision = 0
    }

    private func refreshIdleStatus() {
        if !settings.cloudSyncEnabled {
            status = .disabled
        } else if resolvedCredentials() == nil {
            status = .unconfigured
        } else {
            status = .idle(lastSyncedAt: stateStore.state.lastSyncedAt)
        }
    }

    private func resolvedCredentials() -> (origin: CloudSyncOrigin, token: String)? {
        guard settings.cloudSyncEnabled else { return nil }
        return try? validatedCredentials()
    }

    private func validatedCredentials() throws -> (origin: CloudSyncOrigin, token: String) {
        let origin = try CloudSyncOrigin(settings.cloudSyncServerURL)
        let token = secrets.secret(for: SecretAccount.cloudSyncToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw CloudSyncValidationError.missingToken
        }
        return (origin, token)
    }
}
