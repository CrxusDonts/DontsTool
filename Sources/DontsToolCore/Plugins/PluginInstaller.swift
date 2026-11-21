import Combine
import CryptoKit
import Foundation

public struct FetchedPluginCatalog: Equatable, Sendable {
    public let source: PluginSource
    public let catalog: PluginCatalog
    public let resolvedURL: URL
    public let fetchedAt: Date
    public let isSinglePluginFallback: Bool

    public init(
        source: PluginSource,
        catalog: PluginCatalog,
        resolvedURL: URL,
        fetchedAt: Date = Date(),
        isSinglePluginFallback: Bool = false
    ) {
        self.source = source
        self.catalog = catalog
        self.resolvedURL = resolvedURL
        self.fetchedAt = fetchedAt
        self.isSinglePluginFallback = isSinglePluginFallback
    }
}

public struct StagedPluginInstall: Identifiable, Equatable, Sendable {
    public var id: String { manifest.id }

    public let manifest: ResolvedPluginManifest
    public let entry: PluginCatalogEntry
    public let stagingDirectory: URL
    public let packageDirectory: URL
    public let sourceRepo: String
    public let catalogURL: String?
    public let sha256: String
    public let sha256Verified: Bool
    public let isUpdate: Bool
    public let existingVersion: String?
    public let hasSourceConflict: Bool
    public let existingSourceRepo: String?

    public init(
        manifest: ResolvedPluginManifest,
        entry: PluginCatalogEntry,
        stagingDirectory: URL,
        packageDirectory: URL,
        sourceRepo: String,
        catalogURL: String?,
        sha256: String,
        sha256Verified: Bool,
        isUpdate: Bool,
        existingVersion: String?,
        hasSourceConflict: Bool,
        existingSourceRepo: String?
    ) {
        self.manifest = manifest
        self.entry = entry
        self.stagingDirectory = stagingDirectory
        self.packageDirectory = packageDirectory
        self.sourceRepo = sourceRepo
        self.catalogURL = catalogURL
        self.sha256 = sha256
        self.sha256Verified = sha256Verified
        self.isUpdate = isUpdate
        self.existingVersion = existingVersion
        self.hasSourceConflict = hasSourceConflict
        self.existingSourceRepo = existingSourceRepo
    }
}

public enum PluginCatalogInstallStatus: Equatable, Sendable {
    case notInstalled
    case upToDate(installedVersion: String)
    case updateAvailable(installedVersion: String, latestVersion: String)
}

public enum PluginInstallerError: LocalizedError, Equatable, Sendable {
    case invalidSourceLocation(String)
    case catalogNotFound(String)
    case httpStatus(Int, url: String)
    case invalidDownloadURL(String)
    case missingDownloadURL(String)
    case emptyArchive
    case archiveTooLarge(Int)
    case checksumMismatch(pluginID: String, expected: String, actual: String)
    case extractionFailed(String)
    case manifestNotFoundInArchive
    case manifestIDMismatch(expected: String, actual: String)
    case incompatibleHostVersion(pluginID: String, required: String, current: String)
    case sourceConflict(pluginID: String, existingSource: String, incomingSource: String)
    case stagedPackageMissing
    case pluginNotInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSourceLocation(let location):
            "无效的插件源地址：\(location)"
        case .catalogNotFound(let location):
            "未在插件源 \(location) 中找到有效的 catalog.json 或 manifest.json"
        case .httpStatus(let code, let url):
            "下载失败（HTTP \(code)）：\(url)"
        case .invalidDownloadURL(let url):
            "插件下载地址无效（仅允许 HTTPS）：\(url)"
        case .missingDownloadURL(let pluginID):
            "插件 \(pluginID) 未提供 downloadURL 且来源不是 GitHub 仓库"
        case .emptyArchive:
            "下载的插件压缩包为空"
        case .archiveTooLarge(let bytes):
            "插件压缩包体积超出限制（\(bytes) 字节）"
        case .checksumMismatch(let pluginID, let expected, let actual):
            "插件 \(pluginID) SHA-256 校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）"
        case .extractionFailed(let detail):
            "解压插件包失败：\(detail)"
        case .manifestNotFoundInArchive:
            "插件压缩包中未找到 manifest.json"
        case .manifestIDMismatch(let expected, let actual):
            "插件清单 ID 与目录声明不一致（期望 \(expected)，实际 \(actual)）"
        case .incompatibleHostVersion(let pluginID, let required, let current):
            "插件 \(pluginID) 需要 DontsTool \(required) 或更高版本（当前 \(current)）"
        case .sourceConflict(let pluginID, let existingSource, let incomingSource):
            "插件 \(pluginID) 已由源「\(existingSource)」安装，与当前源「\(incomingSource)」不同，需显式确认后方可覆盖"
        case .stagedPackageMissing:
            "待安装的插件暂存目录不存在或已清理，请重新下载检查"
        case .pluginNotInstalled(let pluginID):
            "插件 \(pluginID) 未安装在用户插件目录中"
        }
    }
}

@MainActor
public final class PluginInstaller: ObservableObject {
    public static let installMetadataFilename = ".install-meta.json"
    private static let maxArchiveBytes = 100 * 1024 * 1024

    @Published public private(set) var catalogsBySourceID: [String: FetchedPluginCatalog] = [:]
    @Published public private(set) var loadingSourceIDs: Set<String> = []
    @Published public private(set) var sourceErrors: [String: String] = [:]
    @Published public private(set) var activePluginOperations: Set<String> = []

    public let pluginManager: PluginManager
    public let hostVersion: String

    private let httpClient: any HTTPRequesting
    private let fileManager: FileManager

    public init(
        pluginManager: PluginManager,
        httpClient: any HTTPRequesting = URLSessionHTTPClient(),
        hostVersion: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.pluginManager = pluginManager
        self.httpClient = httpClient
        self.hostVersion = hostVersion ?? pluginManager.hostVersion
        self.fileManager = fileManager
    }

    // MARK: - Catalog Fetching

    @discardableResult
    public func fetchCatalog(for source: PluginSource) async throws -> FetchedPluginCatalog {
        loadingSourceIDs.insert(source.id)
        sourceErrors.removeValue(forKey: source.id)
        defer { loadingSourceIDs.remove(source.id) }

        do {
            let fetched = try await performCatalogFetch(for: source)
            catalogsBySourceID[source.id] = fetched
            return fetched
        } catch {
            sourceErrors[source.id] = error.localizedDescription
            throw error
        }
    }

    public func refreshAllCatalogs(for sources: [PluginSource]) async {
        for source in sources {
            _ = try? await fetchCatalog(for: source)
        }
    }

    // MARK: - Two-Step Install (Inspect -> Commit)

    public func inspectPackage(
        entry: PluginCatalogEntry,
        from source: PluginSource,
        catalogURL: URL? = nil
    ) async throws -> StagedPluginInstall {
        let trimmedID = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PluginManifestLoader.isValidPluginID(trimmedID) else {
            throw PluginManifestError.invalidPluginID(entry.id)
        }

        if let rawMinHost = entry.minHostVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawMinHost.isEmpty {
            guard PluginVersion.parse(rawMinHost) != nil else {
                throw PluginManifestError.invalidMinHostVersion(rawMinHost)
            }
            guard PluginVersion.isSatisfied(minimum: rawMinHost, by: hostVersion) else {
                throw PluginInstallerError.incompatibleHostVersion(
                    pluginID: trimmedID,
                    required: rawMinHost,
                    current: hostVersion
                )
            }
        }

        let trimmedSubpath = entry.subpath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSubpath = (trimmedSubpath?.isEmpty == false) ? trimmedSubpath : nil
        if let normalizedSubpath {
            let segments = normalizedSubpath.split(separator: "/", omittingEmptySubsequences: false)
            guard !normalizedSubpath.hasPrefix("/"),
                  !normalizedSubpath.hasPrefix("~"),
                  !segments.contains(".."),
                  !segments.contains("") else {
                throw PluginCatalogError.invalidSubpath(normalizedSubpath, pluginID: trimmedID)
            }
        }

        let expectedSHA256 = entry.sha256?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpectedSHA = (expectedSHA256?.isEmpty == false) ? expectedSHA256 : nil
        if let normalizedExpectedSHA {
            guard Self.isValidSHA256Hex(normalizedExpectedSHA) else {
                throw PluginCatalogError.invalidSHA256(normalizedExpectedSHA, pluginID: trimmedID)
            }
        }

        activePluginOperations.insert(trimmedID)
        defer { activePluginOperations.remove(trimmedID) }

        let archiveData = try await downloadArchive(for: entry, from: source)
        guard !archiveData.isEmpty else {
            throw PluginInstallerError.emptyArchive
        }
        guard archiveData.count <= Self.maxArchiveBytes else {
            throw PluginInstallerError.archiveTooLarge(archiveData.count)
        }

        let actualSHA256 = Self.sha256Hex(of: archiveData)
        let sha256Verified: Bool
        if let normalizedExpectedSHA {
            guard actualSHA256.caseInsensitiveCompare(normalizedExpectedSHA) == .orderedSame else {
                throw PluginInstallerError.checksumMismatch(
                    pluginID: trimmedID,
                    expected: normalizedExpectedSHA.lowercased(),
                    actual: actualSHA256
                )
            }
            sha256Verified = true
        } else {
            sha256Verified = false
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("DontsTool-PluginStage-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let archiveFileURL = stagingRoot.appendingPathComponent("package.zip")
            try archiveData.write(to: archiveFileURL, options: .atomic)

            let extractDir = stagingRoot.appendingPathComponent("extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

            try await Self.extractZip(archiveURL: archiveFileURL, to: extractDir)
            let hasDirectDownloadURL = entry.downloadURL?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            let packageDir = try locatePackageDirectory(
                in: extractDir,
                subpath: normalizedSubpath,
                allowRootFallback: hasDirectDownloadURL
            )
            try Self.verifyNoEscapingSymlinks(in: packageDir)
            try ensureExecutablePermissions(in: packageDir)

            let resolvedManifest = try PluginManifestLoader.load(
                from: packageDir,
                origin: .user,
                hostVersion: hostVersion
            )
            guard resolvedManifest.id == trimmedID else {
                throw PluginInstallerError.manifestIDMismatch(expected: trimmedID, actual: resolvedManifest.id)
            }

            let existingMeta = installedMetadata(for: resolvedManifest.id)
            let targetDir = try PluginManifestLoader.resolveContainedPath(
                resolvedManifest.id,
                within: pluginManager.userDirectory
            )
            let existingUserRecord = pluginManager.records.first {
                $0.id == resolvedManifest.id && $0.origin == .user
            }
            let isUpdate = fileManager.fileExists(atPath: targetDir.path) || existingUserRecord != nil
            let existingVersion = existingMeta?.version ?? existingUserRecord?.version
            let sourceRepo = source.canonicalRepoIdentifier
            let hasSourceConflict = PluginCatalogValidator.detectSourceConflict(
                incomingPluginID: resolvedManifest.id,
                incomingSourceRepo: sourceRepo,
                existingMetadata: existingMeta
            )
            let resolvedCatalogURL = catalogURL?.absoluteString
                ?? catalogsBySourceID[source.id]?.resolvedURL.absoluteString

            return StagedPluginInstall(
                manifest: resolvedManifest,
                entry: entry,
                stagingDirectory: stagingRoot,
                packageDirectory: packageDir,
                sourceRepo: sourceRepo,
                catalogURL: resolvedCatalogURL,
                sha256: actualSHA256,
                sha256Verified: sha256Verified,
                isUpdate: isUpdate,
                existingVersion: existingVersion,
                hasSourceConflict: hasSourceConflict,
                existingSourceRepo: existingMeta?.sourceRepo
            )
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
    }

    public func commitInstall(
        _ staged: StagedPluginInstall,
        allowSourceOverride: Bool = false
    ) async throws {
        if staged.hasSourceConflict && !allowSourceOverride {
            throw PluginInstallerError.sourceConflict(
                pluginID: staged.manifest.id,
                existingSource: staged.existingSourceRepo ?? "未知来源",
                incomingSource: staged.sourceRepo
            )
        }

        guard fileManager.fileExists(atPath: staged.packageDirectory.path) else {
            throw PluginInstallerError.stagedPackageMissing
        }

        let pluginID = staged.manifest.id
        guard PluginManifestLoader.isValidPluginID(pluginID) else {
            throw PluginManifestError.invalidPluginID(pluginID)
        }

        activePluginOperations.insert(pluginID)
        defer { activePluginOperations.remove(pluginID) }

        let userDirectory = try pluginManager.ensureUserPluginsDirectoryExists()
        let destinationURL = try PluginManifestLoader.resolveContainedPath(pluginID, within: userDirectory)

        let metadata = PluginInstallMetadata(
            pluginID: pluginID,
            version: staged.manifest.version,
            sourceRepo: staged.sourceRepo,
            catalogURL: staged.catalogURL,
            sha256: staged.sha256,
            installedAt: Date()
        )
        let metadataData = try Self.makeMetadataEncoder().encode(metadata)
        let stagedMetadataURL = staged.packageDirectory.appendingPathComponent(Self.installMetadataFilename)
        try metadataData.write(to: stagedMetadataURL, options: .atomic)

        await pluginManager.shutdownPlugin(id: pluginID)

        let incomingTempURL = userDirectory.appendingPathComponent(
            ".install-\(pluginID)-\(UUID().uuidString)",
            isDirectory: true
        )
        let backupTempURL = userDirectory.appendingPathComponent(
            ".backup-\(pluginID)-\(UUID().uuidString)",
            isDirectory: true
        )

        var movedExistingToBackup = false
        do {
            try fileManager.copyItem(at: staged.packageDirectory, to: incomingTempURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: backupTempURL)
                movedExistingToBackup = true
            }
            try fileManager.moveItem(at: incomingTempURL, to: destinationURL)
            if movedExistingToBackup {
                try? fileManager.removeItem(at: backupTempURL)
            }
        } catch {
            try? fileManager.removeItem(at: incomingTempURL)
            if movedExistingToBackup,
               !fileManager.fileExists(atPath: destinationURL.path),
               fileManager.fileExists(atPath: backupTempURL.path) {
                try? fileManager.moveItem(at: backupTempURL, to: destinationURL)
            }
            throw error
        }

        cleanupStagedInstall(staged)
        pluginManager.reload()
    }

    @discardableResult
    public func install(
        entry: PluginCatalogEntry,
        from source: PluginSource,
        catalogURL: URL? = nil,
        allowSourceOverride: Bool = false
    ) async throws -> ResolvedPluginManifest {
        let staged = try await inspectPackage(entry: entry, from: source, catalogURL: catalogURL)
        do {
            try await commitInstall(staged, allowSourceOverride: allowSourceOverride)
            return staged.manifest
        } catch {
            cleanupStagedInstall(staged)
            throw error
        }
    }

    public func cleanupStagedInstall(_ staged: StagedPluginInstall) {
        try? fileManager.removeItem(at: staged.stagingDirectory)
    }

    // MARK: - Uninstall

    public func uninstall(pluginID: String) async throws {
        let trimmedID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PluginManifestLoader.isValidPluginID(trimmedID) else {
            throw PluginManifestError.invalidPluginID(pluginID)
        }

        let targetURL = try PluginManifestLoader.resolveContainedPath(
            trimmedID,
            within: pluginManager.userDirectory
        )
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw PluginInstallerError.pluginNotInstalled(trimmedID)
        }

        activePluginOperations.insert(trimmedID)
        defer { activePluginOperations.remove(trimmedID) }

        await pluginManager.shutdownPlugin(id: trimmedID)
        try fileManager.removeItem(at: targetURL)
        pluginManager.reload()
    }

    // MARK: - Metadata & Status Queries

    public func installedMetadata(for pluginID: String) -> PluginInstallMetadata? {
        let trimmedID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PluginManifestLoader.isValidPluginID(trimmedID),
              let pluginDir = try? PluginManifestLoader.resolveContainedPath(
                  trimmedID,
                  within: pluginManager.userDirectory
              ) else {
            return nil
        }

        let metaURL = pluginDir.appendingPathComponent(Self.installMetadataFilename)
        guard let data = try? Data(contentsOf: metaURL) else {
            return nil
        }
        if let decoded = try? Self.makeMetadataDecoder().decode(PluginInstallMetadata.self, from: data) {
            return decoded
        }
        return try? JSONDecoder().decode(PluginInstallMetadata.self, from: data)
    }

    public func catalogEntryStatus(for entry: PluginCatalogEntry) -> PluginCatalogInstallStatus {
        let trimmedID = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let installedVersion = installedVersion(for: trimmedID)
        guard let installedVersion else {
            return .notInstalled
        }
        if PluginVersion.isNewer(entry.version, than: installedVersion) {
            return .updateAvailable(installedVersion: installedVersion, latestVersion: entry.version)
        }
        return .upToDate(installedVersion: installedVersion)
    }

    public func availableUpdate(
        for pluginID: String
    ) -> (source: PluginSource, entry: PluginCatalogEntry, catalogURL: URL)? {
        let trimmedID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = installedMetadata(for: trimmedID)

        var fallbackMatch: (source: PluginSource, entry: PluginCatalogEntry, catalogURL: URL)?
        for fetched in catalogsBySourceID.values {
            guard let entry = fetched.catalog.plugins.first(where: { $0.id == trimmedID }) else {
                continue
            }
            guard case .updateAvailable = catalogEntryStatus(for: entry) else {
                continue
            }
            if let metadata,
               metadata.sourceRepo.caseInsensitiveCompare(fetched.source.canonicalRepoIdentifier) == .orderedSame {
                return (fetched.source, entry, fetched.resolvedURL)
            }
            if fallbackMatch == nil {
                fallbackMatch = (fetched.source, entry, fetched.resolvedURL)
            }
        }
        return fallbackMatch
    }

    // MARK: - Private Networking

    private func performCatalogFetch(for source: PluginSource) async throws -> FetchedPluginCatalog {
        let location: PluginSourceLocation
        do {
            location = try PluginSourceStore.parseLocation(source.location)
        } catch {
            throw PluginInstallerError.invalidSourceLocation(source.location)
        }

        switch location {
        case let .catalogURL(url):
            let data = try await fetchData(from: url, accept: "application/json", timeout: 20)
            let catalog = try PluginCatalogValidator.decodeAndValidate(data)
            return FetchedPluginCatalog(
                source: source,
                catalog: catalog,
                resolvedURL: url,
                isSinglePluginFallback: false
            )

        case let .gitHubRepo(owner, repo):
            let catalogCandidates: [URL] = [
                URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/catalog.json"),
                URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/catalog.json"),
                URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/master/catalog.json")
            ].compactMap { $0 }

            for candidateURL in catalogCandidates {
                if let data = try await fetchDataAllowingNotFound(from: candidateURL, accept: "application/json", timeout: 20) {
                    let catalog = try PluginCatalogValidator.decodeAndValidate(data)
                    return FetchedPluginCatalog(
                        source: source,
                        catalog: catalog,
                        resolvedURL: candidateURL,
                        isSinglePluginFallback: false
                    )
                }
            }

            if let manifestURL = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/manifest.json"),
               let manifestData = try await fetchDataAllowingNotFound(from: manifestURL, accept: "application/json", timeout: 20) {
                let manifest: PluginManifest
                do {
                    manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
                } catch {
                    throw PluginManifestError.invalidJSON(error.localizedDescription)
                }
                guard manifest.schemaVersion == 1 else {
                    throw PluginManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
                }
                let entry = PluginCatalogEntry(
                    id: manifest.id,
                    name: manifest.name,
                    summary: manifest.description,
                    version: manifest.version,
                    minHostVersion: manifest.minHostVersion,
                    downloadURL: nil,
                    subpath: nil,
                    sha256: nil,
                    ed25519Signature: nil,
                    official: false
                )
                let catalog = PluginCatalog(
                    schemaVersion: 1,
                    sourceName: source.name,
                    plugins: [entry]
                )
                try PluginCatalogValidator.validate(catalog)
                return FetchedPluginCatalog(
                    source: source,
                    catalog: catalog,
                    resolvedURL: manifestURL,
                    isSinglePluginFallback: true
                )
            }

            throw PluginInstallerError.catalogNotFound(source.location)
        }
    }

    private func downloadArchive(for entry: PluginCatalogEntry, from source: PluginSource) async throws -> Data {
        if let rawURL = entry.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty {
            guard let url = URL(string: rawURL),
                  url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty else {
                throw PluginInstallerError.invalidDownloadURL(rawURL)
            }
            return try await fetchData(from: url, accept: "application/zip, application/octet-stream, */*", timeout: 60)
        }

        guard let parsed = source.parsedLocation,
              case let .gitHubRepo(owner, repo) = parsed else {
            throw PluginInstallerError.missingDownloadURL(entry.id)
        }

        let mainURL = URL(string: "https://github.com/\(owner)/\(repo)/archive/refs/heads/main.zip")!
        if let mainData = try await fetchDataAllowingNotFound(
            from: mainURL,
            accept: "application/zip, application/octet-stream, */*",
            timeout: 60
        ) {
            return mainData
        }

        let masterURL = URL(string: "https://github.com/\(owner)/\(repo)/archive/refs/heads/master.zip")!
        return try await fetchData(
            from: masterURL,
            accept: "application/zip, application/octet-stream, */*",
            timeout: 60
        )
    }

    private func fetchData(from url: URL, accept: String, timeout: TimeInterval) async throws -> Data {
        let request = makeRequest(url: url, accept: accept, timeout: timeout)
        let (data, response) = try await httpClient.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PluginInstallerError.httpStatus(http.statusCode, url: url.absoluteString)
        }
        return data
    }

    private func fetchDataAllowingNotFound(
        from url: URL,
        accept: String,
        timeout: TimeInterval
    ) async throws -> Data? {
        let request = makeRequest(url: url, accept: accept, timeout: timeout)
        let (data, response) = try await httpClient.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                return nil
            }
            guard (200...299).contains(http.statusCode) else {
                throw PluginInstallerError.httpStatus(http.statusCode, url: url.absoluteString)
            }
        }
        return data
    }

    private func makeRequest(url: URL, accept: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("DontsTool/\(hostVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - Private Archive & FS Helpers

    private func installedVersion(for pluginID: String) -> String? {
        if let record = pluginManager.records.first(where: {
            $0.id == pluginID && $0.origin == .user && $0.status == .loaded
        }), let version = record.version {
            return version
        }
        if let meta = installedMetadata(for: pluginID) {
            return meta.version
        }
        if let record = pluginManager.records.first(where: {
            $0.id == pluginID && $0.status == .loaded
        }), let version = record.version {
            return version
        }
        return nil
    }

    private func locatePackageDirectory(
        in extractDir: URL,
        subpath: String?,
        allowRootFallback: Bool
    ) throws -> URL {
        if let subpath {
            if let direct = try? PluginManifestLoader.resolveContainedPath(subpath, within: extractDir),
               fileManager.fileExists(atPath: direct.appendingPathComponent("manifest.json").path) {
                return direct
            }
            if let topDir = singleTopLevelDirectory(in: extractDir),
               let nested = try? PluginManifestLoader.resolveContainedPath(subpath, within: topDir),
               fileManager.fileExists(atPath: nested.appendingPathComponent("manifest.json").path) {
                return nested
            }
            guard allowRootFallback else {
                throw PluginInstallerError.manifestNotFoundInArchive
            }
        }

        if fileManager.fileExists(atPath: extractDir.appendingPathComponent("manifest.json").path) {
            return extractDir
        }

        if let topDir = singleTopLevelDirectory(in: extractDir),
           fileManager.fileExists(atPath: topDir.appendingPathComponent("manifest.json").path) {
            return topDir
        }

        throw PluginInstallerError.manifestNotFoundInArchive
    }

    private func singleTopLevelDirectory(in directory: URL) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let filtered = entries.filter { $0.lastPathComponent != "__MACOSX" }
        guard filtered.count == 1, let only = filtered.first else {
            return nil
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: only.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return only
    }

    private func ensureExecutablePermissions(in packageDir: URL) throws {
        let binDir = packageDir.appendingPathComponent("bin", isDirectory: true)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: binDir.path, isDirectory: &isDir), isDir.boolValue {
            if let items = try? fileManager.contentsOfDirectory(
                at: binDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) {
                for item in items {
                    let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values?.isRegularFile == true, values?.isSymbolicLink != true {
                        try makeExecutableIfNeeded(item)
                    }
                }
            }
        }

        let manifestURL = packageDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
              let rawCommandHead = manifest.runtime.command.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCommandHead.isEmpty,
              !rawCommandHead.hasPrefix("/"),
              !rawCommandHead.hasPrefix("$HOST_HELPERS/") else {
            return
        }

        let entryURL = try PluginManifestLoader.resolveContainedPath(rawCommandHead, within: packageDir)
        var entryIsDir: ObjCBool = false
        if fileManager.fileExists(atPath: entryURL.path, isDirectory: &entryIsDir), !entryIsDir.boolValue {
            try makeExecutableIfNeeded(entryURL)
        }
    }

    private func makeExecutableIfNeeded(_ fileURL: URL) throws {
        guard !fileManager.isExecutableFile(atPath: fileURL.path) else { return }
        let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
        let current = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let updated = current | 0o111
        try fileManager.setAttributes([.posixPermissions: updated], ofItemAtPath: fileURL.path)
    }

    private nonisolated static func extractZip(archiveURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]

            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw PluginInstallerError.extractionFailed(error.localizedDescription)
            }

            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let stderrText = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detail = stderrText.isEmpty ? "ditto 退出码 \(process.terminationStatus)" : stderrText
                throw PluginInstallerError.extractionFailed(detail)
            }
        }.value
    }

    private nonisolated static func verifyNoEscapingSymlinks(in directory: URL) throws {
        let fileManager = FileManager.default
        let resolvedRoot = directory.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return
        }
        for case let itemURL as URL in enumerator {
            let values = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                let resolvedTarget = itemURL.standardizedFileURL.resolvingSymlinksInPath()
                guard resolvedTarget.path == resolvedRoot.path || resolvedTarget.path.hasPrefix(rootPrefix) else {
                    throw PluginManifestError.pathTraversal(itemURL.lastPathComponent)
                }
            }
        }
    }

    private static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidSHA256Hex(_ string: String) -> Bool {
        guard string.count == 64 else { return false }
        return string.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9")
                || (scalar >= "a" && scalar <= "f")
                || (scalar >= "A" && scalar <= "F")
        }
    }

    private static func makeMetadataEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeMetadataDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
