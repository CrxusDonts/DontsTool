import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DontsToolCore

@Suite("Cloudflare 多端同步与本地快照备份")
@MainActor
struct CloudSyncTests {
    @MainActor
    private final class ClientFixture {
        let root: URL
        let defaultsName: String
        let defaults: UserDefaults
        let settings: SettingsStore
        let websites: WebsiteShortcutStore
        let searchEngines: SearchEngineStore
        let notes: LocalNoteStore
        let secrets: MemorySecretStore
        let stateStore: SyncStateStore

        init(root: URL, name: String) {
            self.root = root
            defaultsName = "dontstool.cloudsync.tests.\(name).\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            settings = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
            searchEngines = SearchEngineStore(defaults: defaults)
            websites = WebsiteShortcutStore(defaults: defaults, reservedKeywords: { [weak searchEngines] in
                guard let searchEngines else { return [] }
                return SearchEngineKeywordRules.reservedWebsiteKeywords(for: searchEngines.configuration)
            })
            notes = LocalNoteStore(rootURL: root.appendingPathComponent("Notes-\(name)", isDirectory: true))
            secrets = MemorySecretStore()
            stateStore = SyncStateStore(fileURL: root.appendingPathComponent("SyncState-\(name).json"))
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    private final class InMemorySyncServer: HTTPRequesting, @unchecked Sendable {
        private let lock = NSLock()
        private let expectedToken: String
        private var revision: Int64 = 0
        private var blobs: [String: Data] = [:]
        private var items: [String: SyncItemRecord] = [:]
        private var blobUploadCount = 0
        private var blobDownloadCount = 0
        private var blobCheckCount = 0
        private var pushCount = 0
        private var pullCount = 0
        private var pushedKeysLog: [[String]] = []
        private var onPushResponseHook: (@Sendable (Int64, String) async -> Void)?

        init(token: String) {
            expectedToken = token
        }

        var totalBlobUploads: Int { lock.withLock { blobUploadCount } }
        var totalBlobDownloads: Int { lock.withLock { blobDownloadCount } }
        var totalBlobChecks: Int { lock.withLock { blobCheckCount } }
        var totalPushes: Int { lock.withLock { pushCount } }
        var totalPulls: Int { lock.withLock { pullCount } }
        var pushedKeyBatches: [[String]] { lock.withLock { pushedKeysLog } }
        var currentRevision: Int64 { lock.withLock { revision } }

        func setOnPushResponseHook(_ hook: (@Sendable (Int64, String) async -> Void)?) {
            lock.withLock { onPushResponseHook = hook }
        }

        func clearBlobs() {
            lock.withLock { blobs.removeAll() }
        }

        @discardableResult
        func injectRawItem(
            entityKey: String,
            kind: SyncEntityKind,
            deleted: Bool = false,
            updatedAt: Date = Date(),
            deviceId: String = "other-device",
            payload: String? = nil,
            payloadBlobSha256: String? = nil
        ) -> Int64 {
            lock.withLock {
                revision += 1
                let hashSource = deleted ? "deleted:\(entityKey)" : (payload ?? payloadBlobSha256 ?? "")
                let contentHash = SyncDigest.sha256Hex(hashSource)
                items[entityKey] = SyncItemRecord(
                    entityKey: entityKey,
                    kind: kind,
                    revision: revision,
                    deleted: deleted,
                    updatedAt: updatedAt,
                    contentHash: contentHash,
                    deviceId: deviceId,
                    payload: deleted ? nil : payload,
                    payloadBlobSha256: deleted ? nil : payloadBlobSha256
                )
                return revision
            }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let result = try handle(request)
            if let pushHook = result.pushHook {
                await pushHook.callback(pushHook.revision, pushHook.deviceId)
            }
            return (result.data, result.response)
        }

        private struct PushHookInvocation: Sendable {
            let revision: Int64
            let deviceId: String
            let callback: @Sendable (Int64, String) async -> Void
        }

        private func handle(_ request: URLRequest) throws -> (data: Data, response: URLResponse, pushHook: PushHookInvocation?) {
            try lock.withLock {
                let url = request.url!
                let path = url.path
                func makeResponse(_ status: Int, body: Data, pushHook: PushHookInvocation? = nil) -> (Data, URLResponse, PushHookInvocation?) {
                    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "1.1", headerFields: nil)!
                    return (body, response, pushHook)
                }

                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expectedToken)" else {
                    return makeResponse(401, body: Data("{\"error\":\"Unauthorized\"}".utf8))
                }

                if request.httpMethod == "GET" && path == "/v1/health" {
                    let health = SyncHealthResponse(ok: true, revision: revision, itemCount: items.count, serverTime: "2026-11-19T00:00:00Z")
                    return makeResponse(200, body: try SyncJSON.makeEncoder().encode(health))
                }

                if request.httpMethod == "POST" && path == "/v1/blobs/check" {
                    blobCheckCount += 1
                    let req = try SyncJSON.makeDecoder().decode(SyncBlobsCheckRequest.self, from: request.httpBody ?? Data())
                    let missing = req.hashes.filter { blobs[$0] == nil }
                    return makeResponse(200, body: try SyncJSON.makeEncoder().encode(SyncBlobsCheckResponse(missing: missing)))
                }

                if path.hasPrefix("/v1/blobs/") {
                    let sha = String(path.dropFirst("/v1/blobs/".count))
                    if request.httpMethod == "PUT" {
                        let body = request.httpBody ?? Data()
                        guard SyncDigest.sha256Hex(body) == sha else {
                            return makeResponse(400, body: Data("{\"error\":\"SHA mismatch\"}".utf8))
                        }
                        blobs[sha] = body
                        blobUploadCount += 1
                        return makeResponse(200, body: Data("{\"ok\":true}".utf8))
                    }
                    if request.httpMethod == "GET" {
                        guard let data = blobs[sha] else {
                            return makeResponse(404, body: Data("{\"error\":\"Not found\"}".utf8))
                        }
                        blobDownloadCount += 1
                        return makeResponse(200, body: data)
                    }
                }

                if request.httpMethod == "POST" && path == "/v1/sync/push" {
                    pushCount += 1
                    let req = try SyncJSON.makeDecoder().decode(SyncPushRequest.self, from: request.httpBody ?? Data())
                    for mutation in req.mutations {
                        if !mutation.deleted, let blobSha = mutation.payloadBlobSha256, blobs[blobSha] == nil {
                            return makeResponse(409, body: Data("{\"code\":\"missing_blob\",\"error\":\"Missing referenced blob\"}".utf8))
                        }
                    }
                    var revisionConflicts: [SyncRevisionConflict] = []
                    for mutation in req.mutations {
                        let existing = items[mutation.entityKey]
                        if let existing,
                           existing.contentHash == mutation.contentHash && existing.deleted == mutation.deleted {
                            continue
                        }
                        if let expectedRevision = mutation.baseRevision {
                            let currentRevision = existing?.revision ?? 0
                            if currentRevision > expectedRevision {
                                revisionConflicts.append(
                                    SyncRevisionConflict(
                                        entityKey: mutation.entityKey,
                                        expectedRevision: expectedRevision,
                                        currentRevision: currentRevision
                                    )
                                )
                            }
                        }
                    }
                    if !revisionConflicts.isEmpty {
                        struct ConflictResponse: Encodable {
                            let code: String
                            let error: String
                            let conflicts: [SyncRevisionConflict]
                        }
                        let body = try SyncJSON.makeEncoder().encode(
                            ConflictResponse(
                                code: "revision_conflict",
                                error: "Revision conflict on \(revisionConflicts.map(\.entityKey).joined(separator: ", "))",
                                conflicts: revisionConflicts
                            )
                        )
                        return makeResponse(409, body: body)
                    }
                    var applied: [String] = []
                    var itemRevisions: [String: Int64] = [:]
                    for mutation in req.mutations {
                        if let existing = items[mutation.entityKey],
                           existing.contentHash == mutation.contentHash && existing.deleted == mutation.deleted {
                            itemRevisions[mutation.entityKey] = existing.revision
                            continue
                        }
                        revision += 1
                        items[mutation.entityKey] = SyncItemRecord(
                            entityKey: mutation.entityKey,
                            kind: mutation.kind,
                            revision: revision,
                            deleted: mutation.deleted,
                            updatedAt: mutation.updatedAt,
                            contentHash: mutation.contentHash,
                            deviceId: req.deviceId,
                            payload: mutation.deleted ? nil : mutation.payload,
                            payloadBlobSha256: mutation.deleted ? nil : mutation.payloadBlobSha256
                        )
                        applied.append(mutation.entityKey)
                        itemRevisions[mutation.entityKey] = revision
                    }
                    pushedKeysLog.append(applied)
                    let hook = (!applied.isEmpty ? onPushResponseHook : nil).map {
                        PushHookInvocation(revision: revision, deviceId: req.deviceId, callback: $0)
                    }
                    return makeResponse(200, body: try SyncJSON.makeEncoder().encode(SyncPushResponse(revision: revision, appliedKeys: applied, itemRevisions: itemRevisions)), pushHook: hook)
                }

                if request.httpMethod == "GET" && path == "/v1/sync/pull" {
                    pullCount += 1
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let since = Int64(components?.queryItems?.first(where: { $0.name == "since" })?.value ?? "0") ?? 0
                    let limit = Int(components?.queryItems?.first(where: { $0.name == "limit" })?.value ?? "100") ?? 100
                    let ordered = items.values.filter { $0.revision > since }.sorted { $0.revision < $1.revision }
                    let page = Array(ordered.prefix(limit))
                    let pull = SyncPullResponse(changes: page, latestRevision: revision, hasMore: ordered.count > limit)
                    return makeResponse(200, body: try SyncJSON.makeEncoder().encode(pull))
                }

                return makeResponse(404, body: Data("{\"error\":\"Not found\"}".utf8))
            }
        }
    }

    private final class FakeRealtimeClient: SyncRealtimeListening, @unchecked Sendable {
        private let lock = NSLock()
        private var onSyncEvent: (@Sendable (Int64, String) -> Void)?
        private var onConnectionChanged: (@Sendable (Bool) -> Void)?

        func start(
            onSyncEvent: @escaping @Sendable (Int64, String) -> Void,
            onConnectionChanged: @escaping @Sendable (Bool) -> Void
        ) {
            lock.withLock {
                self.onSyncEvent = onSyncEvent
                self.onConnectionChanged = onConnectionChanged
            }
        }

        func stop() {
            lock.withLock {
                onSyncEvent = nil
                onConnectionChanged = nil
            }
        }

        func emitConnected(_ connected: Bool) {
            let callback = lock.withLock { onConnectionChanged }
            callback?(connected)
        }

        func emitSyncEvent(revision: Int64, sourceDeviceID: String) {
            let callback = lock.withLock { onSyncEvent }
            callback?(revision, sourceDeviceID)
        }
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DontsToolCloudSyncTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    private func noteContent(_ text: String, imagePath: String? = nil) -> LocalNoteContent {
        var nodes: [[String: Any]] = [["type": "paragraph", "content": [["type": "text", "text": text]]]]
        if let imagePath {
            nodes.append(["type": "image", "attrs": ["src": imagePath]])
        }
        let data = try! JSONSerialization.data(withJSONObject: ["type": "doc", "content": nodes], options: [.sortedKeys])
        return LocalNoteContent(
            json: String(decoding: data, as: UTF8.self),
            markdown: imagePath.map { "\(text)\n\n![](\($0))" } ?? text,
            plainText: text
        )
    }

    private func samplePNG(fill byte: UInt8 = 120) throws -> Data {
        let bytes = [UInt8](repeating: byte, count: 4)
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 2,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func backupArchiveRoundTripsAllDataAndRejectsTamperedArchives() async throws {
        try await withTempDir { dir in
            let fixture = ClientFixture(root: dir, name: "backup")
            defer { fixture.cleanup() }
            let pngData = try samplePNG()

            let active = try fixture.notes.create(title: "重要工作便笺")
            let asset = try fixture.notes.importImage(pngData, for: active.id)
            _ = try fixture.notes.updateContent(active.id, content: noteContent("正文带图片", imagePath: asset.relativePath))
            _ = try fixture.notes.setPinned(active.id, pinned: true)

            let trashed = try fixture.notes.create(title: "待清理便笺", content: noteContent("废纸篓内容"))
            try fixture.notes.trash(trashed.id)

            let websiteConfig = WebsiteShortcutConfiguration(
                version: 3,
                groups: [.init(keyword: "ops", name: "运维", items: [.init(key: "home", name: "首页", url: "https://ops.example.com")])]
            )
            try fixture.websites.save(websiteConfig)

            var customSearch = SearchEngineConfiguration.builtIn
            customSearch.engines.append(.init(id: "docs", name: "文档", keyword: "docs", urlTemplate: "https://docs.example.com/?q={query}"))
            try fixture.searchEngines.save(customSearch)

            fixture.settings.setHotKey(.doubleTap(.option))
            fixture.settings.setTranslationTarget("en")
            fixture.settings.setTranslationAPIBaseURL("https://api.example.com/v1")
            fixture.settings.setTranslationAPIModel("gpt-5")
            fixture.settings.setSelectionTranslationEnabled(true)

            let archiveURL = dir.appendingPathComponent("DontsTool-Backup.zip")
            try BackupArchiveService.exportArchive(
                to: archiveURL,
                settings: fixture.settings,
                websites: fixture.websites,
                searchEngines: fixture.searchEngines,
                notes: fixture.notes
            )

            // Mutate live state before restoring.
            try fixture.notes.trash(active.id)
            try fixture.notes.deletePermanently(active.id)
            try fixture.notes.deletePermanently(trashed.id)
            try fixture.websites.save(.empty)
            fixture.settings.setHotKey(.optionSpace)
            fixture.settings.setTranslationTarget("ja")

            let safetyDir = dir.appendingPathComponent("SafetyBackups", isDirectory: true)
            try BackupArchiveService.restoreArchive(
                from: archiveURL,
                safetyBackupDirectory: safetyDir,
                settings: fixture.settings,
                websites: fixture.websites,
                searchEngines: fixture.searchEngines,
                notes: fixture.notes
            )

            let restoredActive = try #require(fixture.notes.note(active.id))
            #expect(restoredActive.title == "重要工作便笺")
            #expect(restoredActive.isPinned)
            #expect(restoredActive.content.plainText == "正文带图片")
            let restoredAssetURL = try fixture.notes.assetURL(for: active.id, relativePath: asset.relativePath)
            #expect(try Data(contentsOf: restoredAssetURL) == pngData)
            #expect(fixture.notes.trashedNotes.map(\.id) == [trashed.id])
            #expect(fixture.websites.configuration == websiteConfig)
            #expect(fixture.searchEngines.configuration == customSearch)
            #expect(fixture.settings.hotKey == .doubleTap(.option))
            #expect(fixture.settings.translationTarget == "en")
            #expect(fixture.settings.translationAPIModel == "gpt-5")
            #expect(fixture.settings.selectionTranslationEnabled)

            let safetyFiles = try FileManager.default.contentsOfDirectory(atPath: safetyDir.path)
            #expect(safetyFiles.contains { $0.hasPrefix("pre-restore-") && $0.hasSuffix(".zip") })

            // Tamper with the exported archive and confirm restoration fails without touching live data.
            let tamperedExtract = dir.appendingPathComponent("tampered-extract", isDirectory: true)
            try FileManager.default.createDirectory(at: tamperedExtract, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", archiveURL.path, tamperedExtract.path]
            try unzip.run()
            unzip.waitUntilExit()
            #expect(unzip.terminationStatus == 0)

            let websitesFile = tamperedExtract.appendingPathComponent("DontsToolBackup/configs/websites.json")
            try Data("{\"version\":3,\"groups\":[]}".utf8).write(to: websitesFile)
            let tamperedZip = dir.appendingPathComponent("tampered.zip")
            let rezip = Process()
            rezip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            rezip.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", tamperedExtract.appendingPathComponent("DontsToolBackup").path, tamperedZip.path]
            try rezip.run()
            rezip.waitUntilExit()
            #expect(rezip.terminationStatus == 0)

            #expect(throws: (any Error).self) {
                try BackupArchiveService.restoreArchive(
                    from: tamperedZip,
                    safetyBackupDirectory: safetyDir,
                    settings: fixture.settings,
                    websites: fixture.websites,
                    searchEngines: fixture.searchEngines,
                    notes: fixture.notes
                )
            }
            #expect(fixture.websites.configuration == websiteConfig)
            #expect(fixture.notes.note(active.id)?.title == "重要工作便笺")
        }
    }

    @Test func multiDeviceIncrementalSyncDeduplicatesImageBlobs() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA")
            let macB = ClientFixture(root: dir, name: "MacB")
            defer { macA.cleanup(); macB.cleanup() }

            for fixture in [macA, macB] {
                fixture.settings.setCloudSyncEnabled(true)
                fixture.settings.setCloudSyncServerURL("https://sync.example.com")
                fixture.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)
            }

            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacA" }
            )
            let coordB = CloudSyncCoordinator(
                settings: macB.settings, websites: macB.websites, searchEngines: macB.searchEngines,
                notes: macB.notes, secrets: macB.secrets, httpClient: server, stateStore: macB.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacB" }
            )

            let pngData = try samplePNG(fill: 200)
            let note = try macA.notes.create(title: "共享便笺")
            let asset = try macA.notes.importImage(pngData, for: note.id)
            _ = try macA.notes.updateContent(note.id, content: noteContent("第一版正文", imagePath: asset.relativePath))

            let sites = WebsiteShortcutConfiguration(
                version: 3,
                groups: [.init(keyword: "kb", name: "文档", items: [.init(key: "cf", name: "Cloudflare", url: "https://dash.cloudflare.com")])]
            )
            try macA.websites.save(sites)

            #expect(await coordA.syncNow())
            #expect(server.totalBlobUploads == 1)
            #expect(await coordB.syncNow())

            let syncedOnB = try #require(macB.notes.note(note.id))
            #expect(syncedOnB.title == "共享便笺")
            #expect(syncedOnB.content.plainText == "第一版正文")
            let assetOnB = try macB.notes.assetURL(for: note.id, relativePath: asset.relativePath)
            #expect(try Data(contentsOf: assetOnB) == pngData)
            #expect(macB.websites.configuration == sites)

            // Updating text only must NOT re-upload the unchanged image blob.
            _ = try macA.notes.updateContent(note.id, content: noteContent("第二版正文", imagePath: asset.relativePath))
            #expect(await coordA.syncNow())
            #expect(server.totalBlobUploads == 1)
            #expect(await coordB.syncNow())
            #expect(macB.notes.note(note.id)?.content.plainText == "第二版正文")
        }
    }

    @Test func offlineConcurrentNoteEditsPreserveConflictCopyAndPropagateDeletions() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA")
            let macB = ClientFixture(root: dir, name: "MacB")
            defer { macA.cleanup(); macB.cleanup() }

            for fixture in [macA, macB] {
                fixture.settings.setCloudSyncEnabled(true)
                fixture.settings.setCloudSyncServerURL("https://sync.example.com")
                fixture.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)
            }

            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacA" }
            )
            let coordB = CloudSyncCoordinator(
                settings: macB.settings, websites: macB.websites, searchEngines: macB.searchEngines,
                notes: macB.notes, secrets: macB.secrets, httpClient: server, stateStore: macB.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacB" }
            )

            let note = try macA.notes.create(title: "方案草稿", content: noteContent("初始内容"))
            #expect(await coordA.syncNow())
            #expect(await coordB.syncNow())
            #expect(macB.notes.note(note.id)?.content.plainText == "初始内容")

            // Both edit offline concurrently.
            _ = try macA.notes.updateContent(note.id, content: noteContent("MacA 的修改"))
            _ = try macB.notes.updateContent(note.id, content: noteContent("MacB 的修改"))

            #expect(await coordA.syncNow())
            #expect(await coordB.syncNow())
            #expect(await coordA.syncNow())

            // Both Macs converge to 2 notes: the remote winner + MacB's conflict copy.
            #expect(macA.notes.notes.count == 2)
            #expect(macB.notes.notes.count == 2)
            #expect(macB.notes.note(note.id)?.content.plainText == "MacA 的修改")

            let conflictOnA = try #require(macA.notes.notes.first { $0.id != note.id })
            let conflictOnB = try #require(macB.notes.notes.first { $0.id != note.id })
            #expect(conflictOnA.id == conflictOnB.id)
            #expect(conflictOnA.title.contains("冲突副本 · MacB"))
            #expect(conflictOnA.content.plainText == "MacB 的修改")

            // Permanent deletion propagates via tombstones.
            try macA.notes.trash(conflictOnA.id)
            try macA.notes.deletePermanently(conflictOnA.id)
            #expect(await coordA.syncNow())
            #expect(await coordB.syncNow())
            #expect(macB.notes.notes.map(\.id) == [note.id])
            #expect(macB.notes.trashedNotes.isEmpty)
        }
    }

    @Test func syncsMultiAIModelProfilesAndBindingsAcrossDevicesWithoutKeys() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA-AI")
            let macB = ClientFixture(root: dir, name: "MacB-AI")
            defer { macA.cleanup(); macB.cleanup() }

            for fixture in [macA, macB] {
                fixture.settings.setCloudSyncEnabled(true)
                fixture.settings.setCloudSyncServerURL("https://sync.example.com")
                fixture.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)
            }

            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacA" }
            )
            let coordB = CloudSyncCoordinator(
                settings: macB.settings, websites: macB.websites, searchEngines: macB.searchEngines,
                notes: macB.notes, secrets: macB.secrets, httpClient: server, stateStore: macB.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacB" }
            )

            let gemini = AIModelProfile(
                id: "sync-gemini",
                name: "Gemini 2.5",
                format: .gemini,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                model: "gemini-2.5-flash"
            )
            let openai = AIModelProfile(
                id: "sync-openai",
                name: "OpenAI 主力",
                format: .openAIResponses,
                baseURL: "https://api.openai.com/v1",
                model: "gpt-4.1-mini"
            )
            let customPluginConsumer = AIConsumerID.plugin("com.example.code-review")
            macA.settings.upsertAIModelProfile(gemini, makeDefault: true)
            macA.settings.upsertAIModelProfile(openai)
            macA.settings.setTranslationAIModelProfileID(gemini.id)
            macA.settings.setQuickAIAIModelProfileID(openai.id)
            macA.settings.setAIModelProfileID(openai.id, forConsumerID: customPluginConsumer)
            macA.settings.saveAPIKey("AIza-local-key-only", for: gemini, secrets: macA.secrets)

            #expect(await coordA.syncNow())
            #expect(await coordB.syncNow())

            #expect(macB.settings.aiModelProfiles == [gemini, openai])
            #expect(macB.settings.defaultAIModelProfileID == gemini.id)
            #expect(macB.settings.translationAIModelProfileID == gemini.id)
            #expect(macB.settings.quickAIAIModelProfileID == openai.id)
            #expect(macB.settings.aiModelProfileID(forConsumerID: customPluginConsumer) == openai.id)
            // Secrets remain local to Keychain and never sync over the wire
            #expect(macB.settings.apiKey(for: gemini, secrets: macB.secrets) == nil)
        }
    }

    @Test func preConsumerRegistryProfilesSnapshotMigratesWithoutPingPong() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA-MigratedBindings")
            defer { macA.cleanup() }

            macA.settings.setCloudSyncEnabled(true)
            macA.settings.setCloudSyncServerURL("https://sync.example.com")
            macA.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)

            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacA" }
            )

            // Snapshot from v0.4.2 / v0.4.3 with aiModelProfiles & legacy per-scene IDs, omitting aiConsumerModelBindings
            let v043Payload = """
            {
              "aiAPIFormat": "gemini",
              "aiModelProfiles": [
                {
                  "baseURL": "https://generativelanguage.googleapis.com/v1beta",
                  "format": "gemini",
                  "id": "p-gemini",
                  "model": "gemini-2.5-flash",
                  "name": "Gemini"
                },
                {
                  "baseURL": "https://api.openai.com/v1",
                  "format": "openai_responses",
                  "id": "p-openai",
                  "model": "gpt-4.1-mini",
                  "name": "OpenAI"
                }
              ],
              "applicationSortOrder": "recent",
              "defaultAIModelProfileID": "p-gemini",
              "enabledProviderIDs": ["applications", "translation"],
              "fileSearchEnabled": true,
              "hotKey": {"keyCode": 49, "kind": "combination", "modifiers": 2048},
              "quickAIAIModelProfileID": "p-openai",
              "selectionHoldDelayRawValue": 2,
              "selectionTranslationEnabled": true,
              "translationAIModelProfileID": "p-gemini",
              "translationAPIBaseURL": "https://generativelanguage.googleapis.com/v1beta",
              "translationAPIModel": "gemini-2.5-flash",
              "translationTarget": "zh-Hans"
            }
            """
            server.injectRawItem(entityKey: SyncEntityKey.settings, kind: .config, payload: v043Payload)

            #expect(await coordA.syncNow())
            #expect(macA.settings.aiModelProfileID(forConsumerID: AIConsumerID.translation) == "p-gemini")
            #expect(macA.settings.aiModelProfileID(forConsumerID: AIConsumerID.legacyQuickAIPlugin) == "p-openai")
            #expect(!server.pushedKeyBatches.flatMap { $0 }.contains(SyncEntityKey.settings))

            let pushesAfterPull = server.totalPushes
            #expect(await coordA.syncNow())
            #expect(server.totalPushes == pushesAfterPull)
        }
    }

    @Test func crossVersionSettingsSyncDoesNotPingPong() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA-Compat")
            defer { macA.cleanup() }

            macA.settings.setCloudSyncEnabled(true)
            macA.settings.setCloudSyncServerURL("https://sync.example.com")
            macA.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)

            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacA" }
            )

            // 1. Legacy payload omitting newer fields (aiAPIFormat, preferredTerminalBundleID, aiModelProfiles...).
            let legacyPayload = """
            {
              "applicationSortOrder": "frequency",
              "enabledProviderIDs": ["applications", "notes"],
              "fileSearchEnabled": true,
              "hotKey": {"keyCode": 49, "kind": "combination", "modifiers": 2048},
              "selectionHoldDelayRawValue": 2,
              "selectionTranslationEnabled": false,
              "translationAPIBaseURL": "https://legacy.example.com/v1",
              "translationAPIModel": "gpt-4o-mini",
              "translationTarget": "en"
            }
            """
            server.injectRawItem(entityKey: SyncEntityKey.settings, kind: .config, payload: legacyPayload)

            #expect(await coordA.syncNow())
            #expect(macA.settings.translationTarget == "en")
            #expect(macA.settings.translationAPIModel == "gpt-4o-mini")
            // First sync may push initial websites/searchEngines baselines, but must NOT push settings back.
            let pushesAfterLegacyPull = server.totalPushes
            #expect(!server.pushedKeyBatches.flatMap { $0 }.contains(SyncEntityKey.settings))

            // Second sync pass must remain completely quiet (no ping-pong).
            #expect(await coordA.syncNow())
            #expect(server.totalPushes == pushesAfterLegacyPull)

            // 2. Future payload containing extra unknown fields.
            let futurePayload = """
            {
              "aiAPIFormat": "gemini",
              "applicationSortOrder": "recent",
              "enabledProviderIDs": ["applications", "calculator"],
              "fileSearchEnabled": false,
              "futureFlag": true,
              "hotKey": {"keyCode": 49, "kind": "combination", "modifiers": 2048},
              "preferredTerminalBundleID": "com.apple.Terminal",
              "selectionHoldDelayRawValue": 2,
              "selectionTranslationEnabled": true,
              "translationAPIBaseURL": "https://future.example.com/v1",
              "translationAPIModel": "gemini-3-flash",
              "translationTarget": "ja"
            }
            """
            server.injectRawItem(entityKey: SyncEntityKey.settings, kind: .config, payload: futurePayload)

            #expect(await coordA.syncNow())
            #expect(macA.settings.translationTarget == "ja")
            #expect(macA.settings.aiAPIFormat == .gemini)
            #expect(server.totalPushes == pushesAfterLegacyPull)

            #expect(await coordA.syncNow())
            #expect(server.totalPushes == pushesAfterLegacyPull)
        }
    }

    @Test func realtimeSelfEchoDoesNotTriggerDuplicatePullAndConnectedLocalEditSkipsPrePull() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA-RT")
            defer { macA.cleanup() }

            macA.settings.setCloudSyncEnabled(true)
            macA.settings.setCloudSyncServerURL("https://sync.example.com")
            macA.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)

            let fakeRealtime = FakeRealtimeClient()
            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: { _, _ in fakeRealtime },
                deviceNameProvider: { "MacA" },
                debounceDuration: .milliseconds(50)
            )
            defer { coordA.stop() }

            coordA.start()
            for _ in 0..<50 where server.totalPulls == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            fakeRealtime.emitConnected(true)
            for _ in 0..<50 where !coordA.isRealtimeConnected {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(coordA.isRealtimeConnected)
            #expect(await coordA.syncNow())
            let baselinePulls = server.totalPulls

            // Simulate WS push broadcast arriving BEFORE HTTP push returns.
            server.setOnPushResponseHook { rev, src in
                fakeRealtime.emitSyncEvent(revision: rev, sourceDeviceID: src)
                try? await Task.sleep(for: .milliseconds(30))
            }

            _ = try macA.notes.create(title: "本地实时编辑", content: noteContent("第一条本地正文"))
            for _ in 0..<100 where server.totalPushes < 1 || coordA.status == .syncing {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(40))

            #expect(server.totalPushes == 1)
            #expect(server.totalPulls == baselinePulls)

            // Inject an out-of-band remote note without WS notification to verify revision-gap safety net.
            server.setOnPushResponseHook(nil)
            let remoteNoteID = UUID()
            let remoteRecord = LocalNoteRecord(
                id: remoteNoteID,
                title: "远端漏网便笺",
                content: noteContent("来自远端")
            )
            let remotePayload = String(
                decoding: try SyncJSON.makeEncoder().encode(
                    SyncedNotePayload(record: remoteRecord, isTrashed: false, assets: [])
                ),
                as: UTF8.self
            )
            server.injectRawItem(entityKey: SyncEntityKey.note(remoteNoteID), kind: .note, payload: remotePayload)

            _ = try macA.notes.create(title: "本地第二条", content: noteContent("触发 revision gap 检测"))
            for _ in 0..<100 where server.totalPushes < 2 || coordA.status == .syncing || macA.notes.note(remoteNoteID) == nil {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(macA.notes.note(remoteNoteID)?.content.plainText == "来自远端")
            #expect(server.totalPulls == baselinePulls + 1)
        }
    }

    @Test func unchangedNoteImagesSkipBlobCheckOnPushAndReuseLocalBlobOnPull() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA-Blob")
            let macB = ClientFixture(root: dir, name: "MacB-Blob")
            defer { macA.cleanup(); macB.cleanup() }

            for fixture in [macA, macB] {
                fixture.settings.setCloudSyncEnabled(true)
                fixture.settings.setCloudSyncServerURL("https://sync.example.com")
                fixture.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)
            }

            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacA" }
            )
            let coordB = CloudSyncCoordinator(
                settings: macB.settings, websites: macB.websites, searchEngines: macB.searchEngines,
                notes: macB.notes, secrets: macB.secrets, httpClient: server, stateStore: macB.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacB" }
            )

            let pngData = try samplePNG(fill: 180)
            let note = try macA.notes.create(title: "图文便笺")
            let asset = try macA.notes.importImage(pngData, for: note.id)
            _ = try macA.notes.updateContent(note.id, content: noteContent("v1", imagePath: asset.relativePath))

            #expect(await coordA.syncNow())
            #expect(server.totalBlobChecks == 1)
            #expect(server.totalBlobUploads == 1)
            #expect(await coordB.syncNow())
            #expect(server.totalBlobDownloads == 1)

            // Text-only edit must skip /v1/blobs/check on push and reuse local asset on pull.
            _ = try macA.notes.updateContent(note.id, content: noteContent("v2", imagePath: asset.relativePath))
            #expect(await coordA.syncNow())
            #expect(server.totalBlobChecks == 1)
            #expect(server.totalBlobUploads == 1)
            #expect(await coordB.syncNow())
            #expect(server.totalBlobDownloads == 1)
            #expect(macB.notes.note(note.id)?.content.plainText == "v2")

            // Large (>64 KiB) note payload self-heals on HTTP 409 when cached blob disappears from server.
            let largeText = String(repeating: "a", count: CloudSyncClient.inlinePayloadLimit + 2048)
            let largeNote = try macA.notes.create(title: "超大正文便笺", content: noteContent(largeText))
            #expect(await coordA.syncNow())
            #expect(server.totalBlobUploads == 2)

            server.clearBlobs()
            macA.stateStore.state.items[SyncEntityKey.note(largeNote.id)]?.contentHash = "outdated-hash"
            #expect(await coordA.syncNow())
            #expect(server.totalBlobUploads == 3)
            #expect(await coordB.syncNow())
            #expect(macB.notes.note(largeNote.id)?.content.plainText == largeText)
        }
    }

    @Test func syncStateSnapshotDecodesLegacyStateWithoutKnownRemoteBlobHashes() throws {
        let legacyJSON = """
        {
          "items": {
            "config:settings": {
              "contentHash": "abc123",
              "deleted": false,
              "revision": 42,
              "updatedAt": "2026-11-21T18:48:28Z"
            }
          },
          "lastPulledRevision": 42,
          "lastSyncedAt": "2026-11-21T19:13:38Z",
          "localConfigUpdatedAt": {},
          "schemaVersion": 1,
          "serverOrigin": "https://sync.example.com"
        }
        """
        let decoded = try SyncJSON.makeDecoder().decode(SyncStateSnapshot.self, from: Data(legacyJSON.utf8))
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.lastPulledRevision == 42)
        #expect(decoded.items["config:settings"]?.revision == 42)
        #expect(decoded.knownRemoteBlobHashes.isEmpty)
        #expect(decoded.pendingConflicts.isEmpty)
        #expect(decoded.preservedUnknownSettingsJSON == nil)
    }

    @Test func configMergerComputesFieldDiffsCherryPicksAndPreservesUnknownSettingsFields() throws {
        let localJSON = """
        {
          "hotKey": {"keyCode": 49, "kind": "combination", "modifiers": 2048},
          "preferredTerminalBundleID": "com.mitchellh.ghostty",
          "translationTarget": "zh-Hans"
        }
        """
        let remoteJSON = """
        {
          "futureExperimentalFlag": true,
          "hotKey": {"keyCode": 49, "kind": "combination", "modifiers": 2048},
          "preferredTerminalBundleID": "com.apple.Terminal",
          "translationTarget": "en"
        }
        """

        let diffs = SyncConfigMerger.topLevelFieldDiffs(
            entityKey: SyncEntityKey.settings,
            localJSON: localJSON,
            remoteJSON: remoteJSON
        )
        #expect(diffs.map(\.key) == ["futureExperimentalFlag", "preferredTerminalBundleID", "translationTarget"])
        #expect(diffs.first { $0.key == "futureExperimentalFlag" }?.kind == .added)
        #expect(diffs.first { $0.key == "translationTarget" }?.displayName == "翻译目标语言")

        let merged = try SyncConfigMerger.buildMergedJSON(
            localJSON: localJSON,
            remoteJSON: remoteJSON,
            choices: [
                "preferredTerminalBundleID": .local,
                "translationTarget": .remote,
                "futureExperimentalFlag": .remote
            ]
        )
        let mergedObj = try #require(
            try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
        )
        #expect(mergedObj["preferredTerminalBundleID"] as? String == "com.mitchellh.ghostty")
        #expect(mergedObj["translationTarget"] as? String == "en")
        #expect(mergedObj["futureExperimentalFlag"] as? Bool == true)

        let extracted = try #require(SyncConfigMerger.extractUnknownSettingsFields(from: Data(remoteJSON.utf8)))
        let reencodedLocal = Data(#"{"translationTarget":"ja"}"#.utf8)
        let reinjected = SyncConfigMerger.injectUnknownSettingsFields(extracted, into: reencodedLocal)
        let reinjectedObj = try #require(
            try JSONSerialization.jsonObject(with: reinjected) as? [String: Any]
        )
        #expect(reinjectedObj["translationTarget"] as? String == "ja")
        #expect(reinjectedObj["futureExperimentalFlag"] as? Bool == true)
    }

    @Test func concurrentConfigEditsRaiseConflictAndResolveAllThreeWays() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA-Conflict")
            let macB = ClientFixture(root: dir, name: "MacB-Conflict")
            defer { macA.cleanup(); macB.cleanup() }

            for fixture in [macA, macB] {
                fixture.settings.setCloudSyncEnabled(true)
                fixture.settings.setCloudSyncServerURL("https://sync.example.com")
                fixture.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)
            }

            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacA" },
                debounceDuration: .seconds(60)
            )
            let coordB = CloudSyncCoordinator(
                settings: macB.settings, websites: macB.websites, searchEngines: macB.searchEngines,
                notes: macB.notes, secrets: macB.secrets, httpClient: server, stateStore: macB.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacB" },
                debounceDuration: .seconds(60)
            )
            defer { coordA.stop(); coordB.stop() }

            coordA.start()
            coordB.start()
            try await Task.sleep(for: .milliseconds(30))
            while coordA.status == .syncing || coordB.status == .syncing {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await coordA.syncNow())
            #expect(await coordB.syncNow())

            // Both edit config:settings offline concurrently.
            let proProfile = AIModelProfile(
                id: "vertex-pro",
                name: "Gemini 4",
                format: .gemini,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                model: "gemini-4-hydrogen"
            )
            macA.settings.setHotKey(.doubleTap(.option))
            macA.settings.upsertAIModelProfile(proProfile, makeDefault: true)
            #expect(await coordA.syncNow())

            macB.settings.setTranslationTarget("en")
            macB.settings.setPreferredTerminalBundleID("com.mitchellh.ghostty")
            let noteOnB = try macB.notes.create(title: "离线笔记", content: noteContent("冲突期间仍需正常同步"))

            #expect(await coordB.syncNow())
            // Non-conflicting note syncs even while config:settings has an unresolved conflict.
            #expect(await coordA.syncNow())
            #expect(macA.notes.note(noteOnB.id)?.content.plainText == "冲突期间仍需正常同步")

            // Mac B must pause config:settings with .concurrentModification instead of overwriting.
            #expect(coordB.pendingConflicts.count == 1)
            let conflict = try #require(coordB.pendingConflicts.first)
            #expect(conflict.entityKey == SyncEntityKey.settings)
            #expect(conflict.reason == .concurrentModification)
            if case .needsResolution(let count, _) = coordB.status {
                #expect(count == 1)
            } else {
                Issue.record("Expected needsResolution status, got \(coordB.status)")
            }
            #expect(macB.settings.translationTarget == "en")
            #expect(macB.settings.aiModelProfiles.isEmpty)

            // Resolve via cherry-picked merged JSON (take Mac A's AI profiles/default + Mac B's translationTarget/terminal).
            let mergedJSON = try SyncConfigMerger.buildMergedJSON(
                localJSON: conflict.localJSON,
                remoteJSON: conflict.remoteJSON,
                choices: [
                    "aiModelProfiles": .remote,
                    "defaultAIModelProfileID": .remote,
                    "hotKey": .remote,
                    "translationTarget": .local,
                    "preferredTerminalBundleID": .local
                ]
            )
            try await coordB.resolveConflict(entityKey: SyncEntityKey.settings, resolution: .useMergedJSON(mergedJSON))
            #expect(coordB.pendingConflicts.isEmpty)
            #expect(await coordA.syncNow())

            #expect(macA.settings.translationTarget == "en")
            #expect(macA.settings.preferredTerminalBundleID == "com.mitchellh.ghostty")
            #expect(macA.settings.aiModelProfiles == [proProfile])
            #expect(macB.settings.aiModelProfiles == [proProfile])
            #expect(!coordB.configHistory(for: SyncEntityKey.settings).isEmpty)

            // Also test .keepLocal and .useRemote + restoreConfigHistory on searchEngines and websites.
            var searchA = macA.searchEngines.configuration
            searchA.defaultEngineID = "bing"
            try macA.searchEngines.save(searchA)
            #expect(await coordA.syncNow())

            var searchB = macB.searchEngines.configuration
            searchB.defaultEngineID = "baidu"
            try macB.searchEngines.save(searchB)
            #expect(await coordB.syncNow())
            #expect(coordB.pendingConflicts.contains { $0.entityKey == SyncEntityKey.searchEngines })
            try await coordB.resolveConflict(entityKey: SyncEntityKey.searchEngines, resolution: .keepLocal)
            #expect(await coordA.syncNow())
            #expect(macA.searchEngines.configuration.defaultEngineID == "baidu")

            let sitesA = WebsiteShortcutConfiguration(
                version: 3,
                groups: [.init(keyword: "dev", name: "开发", items: [.init(key: "gh", name: "GitHub", url: "https://github.com")])]
            )
            try macA.websites.save(sitesA)
            #expect(await coordA.syncNow())

            let sitesB = WebsiteShortcutConfiguration(
                version: 3,
                groups: [.init(keyword: "ops", name: "运维", items: [.init(key: "cf", name: "CF", url: "https://dash.cloudflare.com")])]
            )
            try macB.websites.save(sitesB)
            #expect(await coordB.syncNow())
            #expect(coordB.pendingConflicts.contains { $0.entityKey == SyncEntityKey.websites })
            try await coordB.resolveConflict(entityKey: SyncEntityKey.websites, resolution: .useRemote)
            #expect(macB.websites.configuration == sitesA)

            let websiteHistory = try #require(coordB.configHistory(for: SyncEntityKey.websites).first)
            try await coordB.restoreConfigHistory(websiteHistory)
            #expect(macB.websites.configuration == sitesB)
        }
    }

    @Test func initialSyncWithCustomizedLocalConfigRaisesConflictWhileFreshMacAutoAdopts() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA-Init")
            let macB = ClientFixture(root: dir, name: "MacB-Custom")
            let macC = ClientFixture(root: dir, name: "MacC-Fresh")
            defer { macA.cleanup(); macB.cleanup(); macC.cleanup() }

            for fixture in [macA, macB, macC] {
                fixture.settings.setCloudSyncEnabled(true)
                fixture.settings.setCloudSyncServerURL("https://sync.example.com")
                fixture.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)
            }

            var customSearchA = SearchEngineConfiguration.builtIn
            customSearchA.defaultEngineID = "bing"
            try macA.searchEngines.save(customSearchA)
            macA.settings.setHotKey(.doubleTap(.option))

            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacA" }
            )
            #expect(await coordA.syncNow())

            // Mac B has customized searchEngines & settings before first sync -> must raise .initialDivergence.
            var customSearchB = SearchEngineConfiguration.builtIn
            customSearchB.engines.append(.init(id: "docs", name: "文档", keyword: "docs", urlTemplate: "https://docs.example.com/?q={query}"))
            try macB.searchEngines.save(customSearchB)
            macB.settings.setPreferredTerminalBundleID("com.apple.Terminal")

            let coordB = CloudSyncCoordinator(
                settings: macB.settings, websites: macB.websites, searchEngines: macB.searchEngines,
                notes: macB.notes, secrets: macB.secrets, httpClient: server, stateStore: macB.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacB" }
            )
            #expect(await coordB.syncNow())
            let conflictKeys = Set(coordB.pendingConflicts.map(\.entityKey))
            #expect(conflictKeys.contains(SyncEntityKey.searchEngines))
            #expect(conflictKeys.contains(SyncEntityKey.settings))
            #expect(coordB.pendingConflicts.allSatisfy { $0.reason == .initialDivergence })
            #expect(macB.searchEngines.configuration == customSearchB)

            // Mac C has untouched defaults -> auto-adopts cleanly with 0 conflicts.
            let coordC = CloudSyncCoordinator(
                settings: macC.settings, websites: macC.websites, searchEngines: macC.searchEngines,
                notes: macC.notes, secrets: macC.secrets, httpClient: server, stateStore: macC.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacC" }
            )
            #expect(await coordC.syncNow())
            #expect(coordC.pendingConflicts.isEmpty)
            #expect(macC.searchEngines.configuration.defaultEngineID == "bing")
            #expect(macC.settings.hotKey == .doubleTap(.option))
        }
    }

    @Test func remoteDowngradeGuardBlocksOldMacStrippingAIProfilesOrPushingStaleTimestamp() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA-Modern")
            defer { macA.cleanup() }

            macA.settings.setCloudSyncEnabled(true)
            macA.settings.setCloudSyncServerURL("https://sync.example.com")
            macA.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)

            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: nil, deviceNameProvider: { "MacA" }
            )
            coordA.start()
            defer { coordA.stop() }

            let model = AIModelProfile(
                id: "modern-ai",
                name: "Gemini",
                format: .gemini,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                model: "gemini-4-hydrogen"
            )
            macA.settings.upsertAIModelProfile(model, makeDefault: true)
            macA.settings.setAIModelProfileID(model.id, forConsumerID: AIConsumerID.translation)
            #expect(await coordA.syncNow())

            // Simulate an older Mac pushing a newer revision that omits aiModelProfiles & aiConsumerModelBindings.
            let strippedOldPayload = """
            {
              "applicationSortOrder": "recent",
              "enabledProviderIDs": ["applications", "notes"],
              "fileSearchEnabled": true,
              "hotKey": {"keyCode": 49, "kind": "combination", "modifiers": 2048},
              "selectionHoldDelayRawValue": 2,
              "selectionTranslationEnabled": false,
              "translationAPIBaseURL": "",
              "translationAPIModel": "",
              "translationTarget": "zh-Hans"
            }
            """
            server.injectRawItem(
                entityKey: SyncEntityKey.settings,
                kind: .config,
                updatedAt: Date().addingTimeInterval(60),
                deviceId: "old-mac",
                payload: strippedOldPayload
            )

            #expect(await coordA.syncNow())
            #expect(macA.settings.aiModelProfiles == [model])
            let conflict = try #require(coordA.pendingConflicts.first { $0.entityKey == SyncEntityKey.settings })
            #expect(conflict.reason == .remoteDowngradeGuard)

            // Resolve keeping local, then simulate an older timestamp push while keeping schema intact.
            try await coordA.resolveConflict(entityKey: SyncEntityKey.settings, resolution: .keepLocal)
            #expect(coordA.pendingConflicts.isEmpty)

            var staleObj = try #require(
                try JSONSerialization.jsonObject(
                    with: SyncJSON.makeEncoder().encode(macA.settings.exportSyncedSettings())
                ) as? [String: Any]
            )
            staleObj["translationTarget"] = "en"
            let staleData = try JSONSerialization.data(withJSONObject: staleObj, options: [.sortedKeys])
            server.injectRawItem(
                entityKey: SyncEntityKey.settings,
                kind: .config,
                updatedAt: Date.distantPast,
                deviceId: "old-mac-stale-ts",
                payload: String(decoding: staleData, as: UTF8.self)
            )

            #expect(await coordA.syncNow())
            #expect(macA.settings.translationTarget == "zh-Hans")
            let staleConflict = try #require(coordA.pendingConflicts.first { $0.entityKey == SyncEntityKey.settings })
            #expect(staleConflict.reason == .remoteDowngradeGuard)
        }
    }

    @Test func serverBaseRevisionOptimisticLockPreventsOverwriteWhenSkippingPrePull() async throws {
        try await withTempDir { dir in
            let server = InMemorySyncServer(token: "sync-secret")
            let macA = ClientFixture(root: dir, name: "MacA-CAS")
            defer { macA.cleanup() }

            macA.settings.setCloudSyncEnabled(true)
            macA.settings.setCloudSyncServerURL("https://sync.example.com")
            macA.secrets.setSecret("sync-secret", for: SecretAccount.cloudSyncToken)

            // Verify makeConfigItem does not fabricate Date() when localConfigUpdatedAt is missing.
            let builder = CloudSyncSnapshotBuilder(
                settings: macA.settings,
                websites: macA.websites,
                searchEngines: macA.searchEngines,
                notes: macA.notes,
                stateStore: macA.stateStore
            )
            let unrecorded = try #require(try builder.buildLocalItem(for: SyncEntityKey.settings))
            #expect(unrecorded.updatedAt == .distantPast)

            let fakeRealtime = FakeRealtimeClient()
            let coordA = CloudSyncCoordinator(
                settings: macA.settings, websites: macA.websites, searchEngines: macA.searchEngines,
                notes: macA.notes, secrets: macA.secrets, httpClient: server, stateStore: macA.stateStore,
                realtimeClientFactory: { _, _ in fakeRealtime },
                deviceNameProvider: { "MacA" },
                debounceDuration: .milliseconds(50)
            )
            defer { coordA.stop() }

            coordA.start()
            for _ in 0..<50 where server.totalPulls == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            fakeRealtime.emitConnected(true)
            for _ in 0..<50 where !coordA.isRealtimeConnected {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await coordA.syncNow())

            // Inject an out-of-band remote settings change WITHOUT emitting WS, so local edit skips pre-pull.
            let remotePayload = """
            {
              "applicationSortOrder": "frequency",
              "enabledProviderIDs": ["applications", "notes"],
              "fileSearchEnabled": true,
              "hotKey": {"keyCode": 49, "kind": "combination", "modifiers": 2048},
              "selectionHoldDelayRawValue": 2,
              "selectionTranslationEnabled": false,
              "translationAPIBaseURL": "",
              "translationAPIModel": "",
              "translationTarget": "ja"
            }
            """
            let remoteRev = server.injectRawItem(
                entityKey: SyncEntityKey.settings,
                kind: .config,
                updatedAt: Date().addingTimeInterval(5),
                deviceId: "other-mac",
                payload: remotePayload
            )

            // Local edit skips initial pull -> pushes stale baseRevision -> hits 409 revision_conflict -> auto-pulls & raises conflict!
            macA.settings.setTranslationTarget("en")
            for _ in 0..<100 where coordA.pendingConflicts.isEmpty {
                try await Task.sleep(for: .milliseconds(15))
            }

            let conflict = try #require(coordA.pendingConflicts.first { $0.entityKey == SyncEntityKey.settings })
            #expect(conflict.reason == .concurrentModification)
            #expect(conflict.remoteRevision == remoteRev)
            // Server must still retain other-mac's revision untouched (no blind overwrite).
            #expect(server.currentRevision == remoteRev)
            #expect(macA.settings.translationTarget == "en")
        }
    }
}
