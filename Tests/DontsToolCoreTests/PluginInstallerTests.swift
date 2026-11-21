import CryptoKit
import Foundation
import os
import Testing
@testable import DontsToolCore

private final class RouteMockHTTPClient: HTTPRequesting, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var routes: [String: (status: Int, data: Data)] = [:]
        var requestedURLs: [String] = []
    }

    var requestedURLs: [String] {
        state.withLock(\.requestedURLs)
    }

    func register(url: String, status: Int = 200, data: Data) {
        state.withLock { $0.routes[url] = (status, data) }
    }

    func registerJSON(url: String, status: Int = 200, json: String) {
        register(url: url, status: status, data: Data(json.utf8))
    }

    func resetRequests() {
        state.withLock { $0.requestedURLs.removeAll() }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let urlString = request.url?.absoluteString ?? ""
        let matched = state.withLock { state -> (status: Int, data: Data) in
            state.requestedURLs.append(urlString)
            return state.routes[urlString] ?? (404, Data())
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: matched.status,
            httpVersion: "1.1",
            headerFields: nil
        )!
        return (matched.data, response)
    }
}

@Suite("PluginInstaller")
@MainActor
struct PluginInstallerTests {
    private func makeSandbox() throws -> (
        root: URL,
        userDir: URL,
        registry: ToolRegistry,
        manager: PluginManager,
        defaults: UserDefaults,
        suite: String
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginInstallerTests-\(UUID().uuidString)", isDirectory: true)
        let userDir = root.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        let suite = "PluginInstallerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        let pluginSettings = PluginSettingsStore(defaults: defaults)
        let host = PluginHostContext(
            settings: settings,
            pluginSettings: pluginSettings,
            hostVersion: "0.2.14"
        )
        let registry = ToolRegistry(providers: [])
        let manager = PluginManager(userDirectory: userDir, registry: registry, hostContext: host)
        return (root, userDir, registry, manager, defaults, suite)
    }

    private func makePluginZip(
        in workRoot: URL,
        pluginID: String,
        name: String,
        version: String,
        keyword: String,
        minHostVersion: String? = nil,
        wrapInTopFolder: String? = nil,
        subpath: String? = nil,
        executablePermissions: Int = 0o644,
        resultTitle: String = "Installed Hit"
    ) throws -> (zipData: Data, sha256: String) {
        let buildDir = workRoot.appendingPathComponent("zip-build-\(UUID().uuidString)", isDirectory: true)
        var targetDir = buildDir
        if let wrapInTopFolder {
            targetDir = targetDir.appendingPathComponent(wrapInTopFolder, isDirectory: true)
        }
        if let subpath {
            targetDir = targetDir.appendingPathComponent(subpath, isDirectory: true)
        }
        let binDir = targetDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let script = """
        #!/bin/sh
        read -r _line
        echo '{"jsonrpc":"2.0","id":1,"result":{"items":[{"title":"\(resultTitle)","canonicalKey":"\(pluginID):hit","score":100,"actions":[]}]}}'
        """
        let runURL = binDir.appendingPathComponent("run")
        try Data(script.utf8).write(to: runURL)
        try FileManager.default.setAttributes([.posixPermissions: executablePermissions], ofItemAtPath: runURL.path)

        let minHostField = minHostVersion.map { "\"minHostVersion\": \"\($0)\"," } ?? ""
        let manifestJSON = """
        {
          "schemaVersion": 1,
          "id": "\(pluginID)",
          "name": "\(name)",
          "version": "\(version)",
          \(minHostField)
          "keywords": ["\(keyword)"],
          "phase": "slow",
          "runsOnEmptyArgument": true,
          "runtime": {
            "mode": "oneshot",
            "command": ["bin/run"],
            "timeoutMs": 1000
          },
          "permissions": ["clipboard.write", "toast"]
        }
        """
        try Data(manifestJSON.utf8).write(to: targetDir.appendingPathComponent("manifest.json"))

        let zipURL = workRoot.appendingPathComponent("pkg-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", buildDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let data = try Data(contentsOf: zipURL)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, hash)
    }

    @Test func fetchesCatalogWithReleaseMainMasterAndSinglePluginFallbacks() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.root)
            sandbox.defaults.removePersistentDomain(forName: sandbox.suite)
        }

        let http = RouteMockHTTPClient()
        let installer = PluginInstaller(pluginManager: sandbox.manager, httpClient: http, hostVersion: "0.2.14")
        let source = PluginSource(id: "src-1", name: "Demo Repo", location: "acme/plugins")

        let validCatalogJSON = """
        {
          "schemaVersion": 1,
          "sourceName": "Acme Plugins",
          "plugins": [
            {
              "id": "com.acme.alpha",
              "name": "Alpha",
              "version": "1.0.0",
              "downloadURL": "https://github.com/acme/plugins/releases/download/v1.0.0/alpha.dontsplugin.zip"
            }
          ]
        }
        """

        // 1. Release asset wins first
        let releaseURL = "https://github.com/acme/plugins/releases/latest/download/catalog.json"
        http.registerJSON(url: releaseURL, json: validCatalogJSON)
        let fromRelease = try await installer.fetchCatalog(for: source)
        #expect(fromRelease.resolvedURL.absoluteString == releaseURL)
        #expect(!fromRelease.isSinglePluginFallback)
        #expect(fromRelease.catalog.plugins.map(\.id) == ["com.acme.alpha"])
        #expect(http.requestedURLs == [releaseURL])

        // 2. Fall back to raw main/catalog.json when release is 404
        let httpMain = RouteMockHTTPClient()
        let installerMain = PluginInstaller(pluginManager: sandbox.manager, httpClient: httpMain, hostVersion: "0.2.14")
        let mainURL = "https://raw.githubusercontent.com/acme/plugins/main/catalog.json"
        httpMain.registerJSON(url: mainURL, json: validCatalogJSON)
        let fromMain = try await installerMain.fetchCatalog(for: source)
        #expect(fromMain.resolvedURL.absoluteString == mainURL)
        #expect(httpMain.requestedURLs == [releaseURL, mainURL])

        // 3. Fall back to raw master/catalog.json when release and main are 404
        let httpMaster = RouteMockHTTPClient()
        let installerMaster = PluginInstaller(pluginManager: sandbox.manager, httpClient: httpMaster, hostVersion: "0.2.14")
        let masterURL = "https://raw.githubusercontent.com/acme/plugins/master/catalog.json"
        httpMaster.registerJSON(url: masterURL, json: validCatalogJSON)
        let fromMaster = try await installerMaster.fetchCatalog(for: source)
        #expect(fromMaster.resolvedURL.absoluteString == masterURL)
        #expect(httpMaster.requestedURLs == [releaseURL, mainURL, masterURL])

        // 4. Single-plugin script repo fallback to raw main/manifest.json
        let httpSingle = RouteMockHTTPClient()
        let installerSingle = PluginInstaller(pluginManager: sandbox.manager, httpClient: httpSingle, hostVersion: "0.2.14")
        let manifestURL = "https://raw.githubusercontent.com/acme/plugins/main/manifest.json"
        httpSingle.registerJSON(url: manifestURL, json: """
        {
          "schemaVersion": 1,
          "id": "com.acme.single",
          "name": "Single Script",
          "version": "0.5.0",
          "description": "单插件仓库",
          "keywords": ["sg"],
          "runtime": { "mode": "oneshot", "command": ["bin/run"] }
        }
        """)
        let fromSingle = try await installerSingle.fetchCatalog(for: source)
        #expect(fromSingle.isSinglePluginFallback)
        #expect(fromSingle.resolvedURL.absoluteString == manifestURL)
        #expect(fromSingle.catalog.plugins.count == 1)
        #expect(fromSingle.catalog.plugins[0].id == "com.acme.single")
        #expect(fromSingle.catalog.plugins[0].summary == "单插件仓库")

        // 5. Direct HTTPS catalog.json URL
        let directURL = "https://plugins.example.com/custom/catalog.json"
        let directSource = PluginSource(id: "src-direct", name: "Custom", location: directURL)
        httpSingle.resetRequests()
        httpSingle.registerJSON(url: directURL, json: validCatalogJSON)
        let fromDirect = try await installerSingle.fetchCatalog(for: directSource)
        #expect(fromDirect.resolvedURL.absoluteString == directURL)
        #expect(httpSingle.requestedURLs == [directURL])
    }

    @Test func enforcesSHA256AndMinHostVersionBeforeAndAfterExtraction() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.root)
            sandbox.defaults.removePersistentDomain(forName: sandbox.suite)
        }

        let http = RouteMockHTTPClient()
        let installer = PluginInstaller(pluginManager: sandbox.manager, httpClient: http, hostVersion: "0.2.14")
        let source = PluginSourceStore.officialSource

        // Pre-download minHostVersion rejection should not even hit network
        let tooNewEntry = PluginCatalogEntry(
            id: "com.donts.future",
            name: "Future",
            version: "1.0.0",
            minHostVersion: "0.3.0",
            downloadURL: "https://github.com/CrxusDonts/DontsTool-Plugins/releases/download/v1.0.0/future.zip"
        )
        await #expect(throws: PluginInstallerError.incompatibleHostVersion(
            pluginID: "com.donts.future",
            required: "0.3.0",
            current: "0.2.14"
        )) {
            _ = try await installer.inspectPackage(entry: tooNewEntry, from: source)
        }
        #expect(http.requestedURLs.isEmpty)

        // Tampered SHA-256 rejection
        let pkg = try makePluginZip(
            in: sandbox.root,
            pluginID: "com.donts.demo",
            name: "Demo",
            version: "1.0.0",
            keyword: "dm"
        )
        let downloadURL = "https://github.com/CrxusDonts/DontsTool-Plugins/releases/download/v1.0.0/demo.zip"
        http.register(url: downloadURL, data: pkg.zipData)

        let wrongHash = String(repeating: "0", count: 64)
        let tamperedEntry = PluginCatalogEntry(
            id: "com.donts.demo",
            name: "Demo",
            version: "1.0.0",
            downloadURL: downloadURL,
            sha256: wrongHash
        )
        await #expect(throws: PluginInstallerError.checksumMismatch(
            pluginID: "com.donts.demo",
            expected: wrongHash,
            actual: pkg.sha256
        )) {
            _ = try await installer.inspectPackage(entry: tamperedEntry, from: source)
        }

        // Manifest ID mismatch rejection
        let mismatchedIDEntry = PluginCatalogEntry(
            id: "com.donts.other",
            name: "Other",
            version: "1.0.0",
            downloadURL: downloadURL,
            sha256: pkg.sha256
        )
        await #expect(throws: PluginInstallerError.manifestIDMismatch(
            expected: "com.donts.other",
            actual: "com.donts.demo"
        )) {
            _ = try await installer.inspectPackage(entry: mismatchedIDEntry, from: source)
        }

        // Manifest-level minHostVersion rejection even when catalog entry omits minHostVersion
        let pkgRequiresNewHost = try makePluginZip(
            in: sandbox.root,
            pluginID: "com.donts.newer",
            name: "Newer Host Only",
            version: "1.0.0",
            keyword: "nw",
            minHostVersion: "0.9.0"
        )
        let newerURL = "https://github.com/CrxusDonts/DontsTool-Plugins/releases/download/v1.0.0/newer.zip"
        http.register(url: newerURL, data: pkgRequiresNewHost.zipData)
        let noCatalogMinHostEntry = PluginCatalogEntry(
            id: "com.donts.newer",
            name: "Newer Host Only",
            version: "1.0.0",
            downloadURL: newerURL,
            sha256: pkgRequiresNewHost.sha256
        )
        await #expect(throws: PluginManifestError.incompatibleHostVersion(required: "0.9.0", current: "0.2.14")) {
            _ = try await installer.inspectPackage(entry: noCatalogMinHostEntry, from: source)
        }
    }

    @Test func twoStepInspectCommitUpdateConflictAndUninstallHotReloadRegistry() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.root)
            sandbox.defaults.removePersistentDomain(forName: sandbox.suite)
        }

        let http = RouteMockHTTPClient()
        let installer = PluginInstaller(pluginManager: sandbox.manager, httpClient: http, hostVersion: "0.2.14")
        let officialSource = PluginSourceStore.officialSource

        // Build v1.0.0 zip with NON-executable 0o644 bin/run inside single top-level folder
        let pkgV1 = try makePluginZip(
            in: sandbox.root,
            pluginID: "com.donts.hello",
            name: "Hello Plugin",
            version: "1.0.0",
            keyword: "hi",
            minHostVersion: "0.2.0",
            wrapInTopFolder: "com.donts.hello",
            executablePermissions: 0o644,
            resultTitle: "Hello v1"
        )
        let v1URL = "https://github.com/CrxusDonts/DontsTool-Plugins/releases/download/v1.0.0/hello.zip"
        http.register(url: v1URL, data: pkgV1.zipData)

        let entryV1 = PluginCatalogEntry(
            id: "com.donts.hello",
            name: "Hello Plugin",
            version: "1.0.0",
            minHostVersion: "0.2.0",
            downloadURL: v1URL,
            sha256: pkgV1.sha256,
            official: true
        )
        #expect(installer.catalogEntryStatus(for: entryV1) == .notInstalled)

        // Step 1: Inspect package (for permission sheet)
        let stagedV1 = try await installer.inspectPackage(entry: entryV1, from: officialSource)
        #expect(stagedV1.manifest.id == "com.donts.hello")
        #expect(stagedV1.manifest.version == "1.0.0")
        #expect(stagedV1.manifest.permissions == [.clipboardWrite, .toast])
        #expect(stagedV1.sha256Verified)
        #expect(stagedV1.sha256 == pkgV1.sha256)
        #expect(!stagedV1.isUpdate)
        #expect(!stagedV1.hasSourceConflict)
        #expect(sandbox.registry.pluginProviders.isEmpty)

        // Step 2: Commit install -> hot reloads ToolRegistry & executes real oneshot search
        try await installer.commitInstall(stagedV1)
        #expect(sandbox.registry.pluginProviders.count == 1)
        #expect(installer.catalogEntryStatus(for: entryV1) == .upToDate(installedVersion: "1.0.0"))

        let metaV1 = try #require(installer.installedMetadata(for: "com.donts.hello"))
        #expect(metaV1.version == "1.0.0")
        #expect(metaV1.sourceRepo == PluginSourceStore.officialRepoLocation)
        #expect(metaV1.sha256 == pkgV1.sha256)

        let providerV1 = try #require(sandbox.registry.pluginProviders.first as? SidecarProvider)
        let hitsV1 = await providerV1.search(SearchContext(
            rawQuery: "hi test",
            mode: .keyword(providerID: providerV1.id, keyword: "hi", argument: "test")
        ))
        #expect(hitsV1.map(\.title) == ["Hello v1"])

        // Step 3: Update to v1.1.0 from same source
        let pkgV2 = try makePluginZip(
            in: sandbox.root,
            pluginID: "com.donts.hello",
            name: "Hello Plugin",
            version: "1.1.0",
            keyword: "hi",
            minHostVersion: "0.2.14",
            resultTitle: "Hello v2"
        )
        let v2URL = "https://github.com/CrxusDonts/DontsTool-Plugins/releases/download/v1.1.0/hello.zip"
        http.register(url: v2URL, data: pkgV2.zipData)

        let entryV2 = PluginCatalogEntry(
            id: "com.donts.hello",
            name: "Hello Plugin",
            version: "1.1.0",
            minHostVersion: "0.2.14",
            downloadURL: v2URL,
            sha256: pkgV2.sha256,
            official: true
        )
        #expect(installer.catalogEntryStatus(for: entryV2) == .updateAvailable(installedVersion: "1.0.0", latestVersion: "1.1.0"))

        // Verify availableUpdate(for:) discovers update from fetched catalog
        let officialCatalogURL = "https://github.com/CrxusDonts/DontsTool-Plugins/releases/latest/download/catalog.json"
        let officialCatalogData = try JSONEncoder().encode(PluginCatalog(
            sourceName: "DontsTool 官方插件仓库",
            plugins: [entryV2]
        ))
        http.register(url: officialCatalogURL, data: officialCatalogData)
        _ = try await installer.fetchCatalog(for: officialSource)
        let pendingUpdate = try #require(installer.availableUpdate(for: "com.donts.hello"))
        #expect(pendingUpdate.source.id == officialSource.id)
        #expect(pendingUpdate.entry.version == "1.1.0")

        let stagedV2 = try await installer.inspectPackage(entry: entryV2, from: officialSource)
        #expect(stagedV2.isUpdate)
        #expect(stagedV2.existingVersion == "1.0.0")
        #expect(!stagedV2.hasSourceConflict)

        try await installer.commitInstall(stagedV2)
        #expect(installer.installedMetadata(for: "com.donts.hello")?.version == "1.1.0")
        let providerV2 = try #require(sandbox.registry.pluginProviders.first as? SidecarProvider)
        let hitsV2 = await providerV2.search(SearchContext(
            rawQuery: "hi test",
            mode: .keyword(providerID: providerV2.id, keyword: "hi", argument: "test")
        ))
        #expect(hitsV2.map(\.title) == ["Hello v2"])

        // Step 4: Cross-source conflict interception + explicit override
        let forkSource = PluginSource(id: "fork", name: "Third Party Fork", location: "mallory/fork-plugins")
        let pkgFork = try makePluginZip(
            in: sandbox.root,
            pluginID: "com.donts.hello",
            name: "Hello Fork",
            version: "2.0.0",
            keyword: "hi",
            resultTitle: "Hello Fork"
        )
        let forkURL = "https://github.com/mallory/fork-plugins/releases/download/v2.0.0/hello.zip"
        http.register(url: forkURL, data: pkgFork.zipData)

        let entryFork = PluginCatalogEntry(
            id: "com.donts.hello",
            name: "Hello Fork",
            version: "2.0.0",
            downloadURL: forkURL,
            sha256: pkgFork.sha256
        )
        let stagedFork = try await installer.inspectPackage(entry: entryFork, from: forkSource)
        #expect(stagedFork.hasSourceConflict)
        #expect(stagedFork.existingSourceRepo == PluginSourceStore.officialRepoLocation)

        await #expect(throws: PluginInstallerError.sourceConflict(
            pluginID: "com.donts.hello",
            existingSource: PluginSourceStore.officialRepoLocation,
            incomingSource: "mallory/fork-plugins"
        )) {
            try await installer.commitInstall(stagedFork, allowSourceOverride: false)
        }
        // Existing installation remains intact after rejected override
        #expect(installer.installedMetadata(for: "com.donts.hello")?.version == "1.1.0")
        #expect(installer.installedMetadata(for: "com.donts.hello")?.sourceRepo == PluginSourceStore.officialRepoLocation)

        // Explicit override succeeds reusing the same staged package
        try await installer.commitInstall(stagedFork, allowSourceOverride: true)
        #expect(installer.installedMetadata(for: "com.donts.hello")?.version == "2.0.0")
        #expect(installer.installedMetadata(for: "com.donts.hello")?.sourceRepo == "mallory/fork-plugins")

        // Step 5: Uninstall removes directory and unloads from ToolRegistry
        try await installer.uninstall(pluginID: "com.donts.hello")
        #expect(sandbox.registry.pluginProviders.isEmpty)
        #expect(sandbox.manager.records.isEmpty)
        #expect(installer.installedMetadata(for: "com.donts.hello") == nil)
        #expect(installer.catalogEntryStatus(for: entryV1) == .notInstalled)

        await #expect(throws: PluginInstallerError.pluginNotInstalled("com.donts.hello")) {
            try await installer.uninstall(pluginID: "com.donts.hello")
        }

        await sandbox.manager.shutdown()
    }

    @Test func installsFromMonorepoSourceArchiveWithSubpath() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.root)
            sandbox.defaults.removePersistentDomain(forName: sandbox.suite)
        }

        let http = RouteMockHTTPClient()
        let installer = PluginInstaller(pluginManager: sandbox.manager, httpClient: http, hostVersion: "0.2.14")
        let source = PluginSource(id: "mono", name: "Mono", location: "team/mono-plugins")

        let archive = try makePluginZip(
            in: sandbox.root,
            pluginID: "com.team.subplugin",
            name: "Subpath Plugin",
            version: "1.0.0",
            keyword: "sub",
            wrapInTopFolder: "mono-plugins-main",
            subpath: "plugins/subplugin",
            executablePermissions: 0o644,
            resultTitle: "From Subpath"
        )
        let archiveURL = "https://github.com/team/mono-plugins/archive/refs/heads/main.zip"
        http.register(url: archiveURL, data: archive.zipData)

        let entry = PluginCatalogEntry(
            id: "com.team.subplugin",
            name: "Subpath Plugin",
            version: "1.0.0",
            subpath: "plugins/subplugin"
        )
        let installed = try await installer.install(entry: entry, from: source)
        #expect(installed.id == "com.team.subplugin")
        #expect(sandbox.registry.pluginProviders.count == 1)

        let provider = try #require(sandbox.registry.pluginProviders.first as? SidecarProvider)
        let hits = await provider.search(SearchContext(
            rawQuery: "sub go",
            mode: .keyword(providerID: provider.id, keyword: "sub", argument: "go")
        ))
        #expect(hits.map(\.title) == ["From Subpath"])

        await sandbox.manager.shutdown()
    }

    @Test func installFromDirectDownloadURLFallsBackToArchiveRootWhenRedundantSubpathIsSet() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.root)
            sandbox.defaults.removePersistentDomain(forName: sandbox.suite)
        }

        let http = RouteMockHTTPClient()
        let installer = PluginInstaller(pluginManager: sandbox.manager, httpClient: http, hostVersion: "0.4.1")
        let source = PluginSource(id: "official", name: "Official", location: "team/plugins")

        let archive = try makePluginZip(
            in: sandbox.root,
            pluginID: "com.team.standalone",
            name: "Standalone Plugin",
            version: "1.1.0",
            keyword: "solo",
            resultTitle: "Root Fallback Hit"
        )
        let downloadURL = "https://github.com/team/plugins/releases/download/v1.1.0/com.team.standalone-1.1.0-macos.dontsplugin.zip"
        http.register(url: downloadURL, data: archive.zipData)

        let entry = PluginCatalogEntry(
            id: "com.team.standalone",
            name: "Standalone Plugin",
            version: "1.1.0",
            downloadURL: downloadURL,
            subpath: "plugins/com.team.standalone",
            sha256: archive.sha256
        )
        let installed = try await installer.install(entry: entry, from: source)
        #expect(installed.id == "com.team.standalone")

        let provider = try #require(sandbox.registry.pluginProviders.first as? SidecarProvider)
        let hits = await provider.search(SearchContext(
            rawQuery: "solo go",
            mode: .keyword(providerID: provider.id, keyword: "solo", argument: "go")
        ))
        #expect(hits.map(\.title) == ["Root Fallback Hit"])

        await sandbox.manager.shutdown()
    }

    @Test func installFromSourceArchiveStillRejectsMissingSubpathWhenDownloadURLIsOmitted() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.root)
            sandbox.defaults.removePersistentDomain(forName: sandbox.suite)
        }

        let http = RouteMockHTTPClient()
        let installer = PluginInstaller(pluginManager: sandbox.manager, httpClient: http, hostVersion: "0.4.1")
        let source = PluginSource(id: "mono", name: "Mono", location: "team/mono-plugins")

        let archive = try makePluginZip(
            in: sandbox.root,
            pluginID: "com.team.wrongpath",
            name: "Wrong Path Plugin",
            version: "1.0.0",
            keyword: "wrong",
            wrapInTopFolder: "mono-plugins-main"
        )
        http.register(url: "https://github.com/team/mono-plugins/archive/refs/heads/main.zip", data: archive.zipData)

        let entry = PluginCatalogEntry(
            id: "com.team.wrongpath",
            name: "Wrong Path Plugin",
            version: "1.0.0",
            subpath: "plugins/does-not-exist"
        )

        do {
            _ = try await installer.inspectPackage(entry: entry, from: source)
            Issue.record("Expected manifestNotFoundInArchive when subpath is missing in repo archive")
        } catch let error as PluginInstallerError {
            #expect(error == .manifestNotFoundInArchive)
        }

        await sandbox.manager.shutdown()
    }
}
