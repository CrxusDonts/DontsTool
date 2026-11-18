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

        init(token: String) {
            expectedToken = token
        }

        var totalBlobUploads: Int {
            lock.withLock { blobUploadCount }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try handle(request)
        }

        private func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
            try lock.withLock {
                let url = request.url!
                let path = url.path
                func makeResponse(_ status: Int, body: Data) -> (Data, URLResponse) {
                    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "1.1", headerFields: nil)!
                    return (body, response)
                }

                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expectedToken)" else {
                    return makeResponse(401, body: Data("{\"error\":\"Unauthorized\"}".utf8))
                }

                if request.httpMethod == "GET" && path == "/v1/health" {
                    let health = SyncHealthResponse(ok: true, revision: revision, itemCount: items.count, serverTime: "2026-11-19T00:00:00Z")
                    return makeResponse(200, body: try SyncJSON.makeEncoder().encode(health))
                }

                if request.httpMethod == "POST" && path == "/v1/blobs/check" {
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
                        return makeResponse(200, body: data)
                    }
                }

                if request.httpMethod == "POST" && path == "/v1/sync/push" {
                    let req = try SyncJSON.makeDecoder().decode(SyncPushRequest.self, from: request.httpBody ?? Data())
                    var applied: [String] = []
                    for mutation in req.mutations {
                        if let existing = items[mutation.entityKey],
                           existing.contentHash == mutation.contentHash && existing.deleted == mutation.deleted {
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
                    }
                    return makeResponse(200, body: try SyncJSON.makeEncoder().encode(SyncPushResponse(revision: revision, appliedKeys: applied)))
                }

                if request.httpMethod == "GET" && path == "/v1/sync/pull" {
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
}
