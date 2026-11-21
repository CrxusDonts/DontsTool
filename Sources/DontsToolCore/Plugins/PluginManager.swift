import Combine
import Foundation

public struct PluginLoadRecord: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case loaded
        case failed(String)
    }

    public let id: String
    public let name: String
    public let version: String?
    public let description: String?
    public let origin: PluginOrigin
    public let directoryURL: URL
    public let manifest: ResolvedPluginManifest?
    public let status: Status
    public let keywords: [String]
    public let permissions: Set<PluginPermission>
    public let legacyProviderID: String?

    public var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }
}

@MainActor
public final class PluginManager: ObservableObject {
    @Published public private(set) var records: [PluginLoadRecord] = []

    public let bundledDirectory: URL?
    public let userDirectory: URL
    public let helpersDirectory: URL?

    private let registry: ToolRegistry
    private let hostContext: PluginHostContext
    private let transportFactory: (ResolvedPluginManifest) -> any PluginTransport
    private var loadedProviders: [SidecarProvider] = []

    public static func defaultUserPluginsDirectory(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("DontsTool", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    public init(
        bundledDirectory: URL? = nil,
        userDirectory: URL = PluginManager.defaultUserPluginsDirectory(),
        helpersDirectory: URL? = nil,
        registry: ToolRegistry,
        hostContext: PluginHostContext,
        transportFactory: ((ResolvedPluginManifest) -> any PluginTransport)? = nil
    ) {
        self.bundledDirectory = bundledDirectory
        self.userDirectory = userDirectory
        self.helpersDirectory = helpersDirectory
        self.registry = registry
        self.hostContext = hostContext
        self.transportFactory = transportFactory ?? { manifest in
            switch manifest.runtimeMode {
            case .oneshot:
                OneShotSidecarTransport(manifest: manifest)
            case .daemon:
                DaemonSidecarTransport(manifest: manifest)
            }
        }
    }

    public func loadAll() {
        shutdownSync()

        var loadedByID: [String: (record: PluginLoadRecord, provider: SidecarProvider)] = [:]
        var orderedIDs: [String] = []
        var failedRecords: [PluginLoadRecord] = []

        if let bundledDirectory {
            scan(
                directory: bundledDirectory,
                origin: .bundled,
                loadedByID: &loadedByID,
                orderedIDs: &orderedIDs,
                failedRecords: &failedRecords
            )
        }

        scan(
            directory: userDirectory,
            origin: .user,
            loadedByID: &loadedByID,
            orderedIDs: &orderedIDs,
            failedRecords: &failedRecords
        )

        let activeProviders = orderedIDs.compactMap { loadedByID[$0]?.provider }
        let loadedRecords = orderedIDs.compactMap { loadedByID[$0]?.record }
        self.loadedProviders = activeProviders
        self.records = loadedRecords + failedRecords
        registry.replacePluginProviders(activeProviders)
    }

    public func reload() {
        loadAll()
    }

    public func isRecordEnabled(_ record: PluginLoadRecord) -> Bool {
        if record.origin == .bundled, let legacyID = record.legacyProviderID {
            return hostContext.settings.isProviderEnabled(legacyID)
        }
        return hostContext.pluginSettings.isPluginEnabled(record.id)
    }

    public func setRecordEnabled(_ record: PluginLoadRecord, to enabled: Bool) {
        if record.origin == .bundled, let legacyID = record.legacyProviderID {
            hostContext.settings.setProviderEnabled(legacyID, to: enabled)
        } else {
            hostContext.pluginSettings.setPluginEnabled(record.id, to: enabled)
        }
    }

    public var hostVersion: String {
        hostContext.hostVersion
    }

    public func ensureUserPluginsDirectoryExists() throws -> URL {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        return userDirectory
    }

    public func shutdownPlugin(id: String) async {
        let matching = loadedProviders.filter { $0.manifest.id == id }
        loadedProviders.removeAll { $0.manifest.id == id }
        for provider in matching {
            await provider.shutdown()
        }
    }

    public func shutdown() async {
        let providers = loadedProviders
        loadedProviders = []
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask {
                    await provider.shutdown()
                }
            }
        }
    }

    public func shutdownSync() {
        let providers = loadedProviders
        loadedProviders = []
        for provider in providers {
            provider.shutdownSync()
        }
    }

    // MARK: - Private

    private func scan(
        directory: URL,
        origin: PluginOrigin,
        loadedByID: inout [String: (record: PluginLoadRecord, provider: SidecarProvider)],
        orderedIDs: inout [String],
        failedRecords: inout [PluginLoadRecord]
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let sortedEntries = entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        for entryURL in sortedEntries {
            guard isDirectory(entryURL, fileManager: fileManager) else { continue }
            let manifestURL = entryURL.appendingPathComponent("manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }

            do {
                let resolved = try PluginManifestLoader.load(
                    from: entryURL,
                    origin: origin,
                    helpersDirectory: helpersDirectory,
                    hostVersion: hostContext.hostVersion
                )
                let transport = transportFactory(resolved)
                let provider = SidecarProvider(manifest: resolved, host: hostContext, transport: transport)
                let record = PluginLoadRecord(
                    id: resolved.id,
                    name: resolved.name,
                    version: resolved.version,
                    description: resolved.description,
                    origin: origin,
                    directoryURL: resolved.directoryURL,
                    manifest: resolved,
                    status: .loaded,
                    keywords: resolved.keywords,
                    permissions: resolved.permissions,
                    legacyProviderID: resolved.legacyProviderID
                )

                if loadedByID[resolved.id] != nil {
                    Log.plugin.info(
                        "外部插件覆盖内置插件：\(resolved.id, privacy: .public)（\(entryURL.path, privacy: .public)）"
                    )
                } else {
                    orderedIDs.append(resolved.id)
                }
                loadedByID[resolved.id] = (record, provider)
            } catch {
                let fallbackInfo = bestEffortRawInfo(at: manifestURL)
                let message = error.localizedDescription
                Log.plugin.error(
                    "加载插件失败（\(entryURL.lastPathComponent, privacy: .public)）：\(message, privacy: .public)"
                )
                failedRecords.append(PluginLoadRecord(
                    id: fallbackInfo.id ?? "invalid.\(entryURL.lastPathComponent)",
                    name: fallbackInfo.name ?? entryURL.lastPathComponent,
                    version: fallbackInfo.version,
                    description: nil,
                    origin: origin,
                    directoryURL: entryURL,
                    manifest: nil,
                    status: .failed(message),
                    keywords: [],
                    permissions: [],
                    legacyProviderID: nil
                ))
            }
        }
    }

    private func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        let resolved = url.resolvingSymlinksInPath()
        return fileManager.fileExists(atPath: resolved.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func bestEffortRawInfo(at manifestURL: URL) -> (id: String?, name: String?, version: String?) {
        guard let data = try? Data(contentsOf: manifestURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        return (
            raw["id"] as? String,
            raw["name"] as? String,
            raw["version"] as? String
        )
    }
}
