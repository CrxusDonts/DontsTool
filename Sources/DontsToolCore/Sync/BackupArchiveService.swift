import Foundation

public enum BackupArchiveError: LocalizedError {
    case invalidArchive(String)
    case zipProcessFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let detail):
            "备份包无效或已损坏：\(detail)"
        case .zipProcessFailed(let detail):
            "备份压缩或解压失败：\(detail)"
        }
    }
}

public struct BackupManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let app: String
    public let createdAt: Date
    public let files: [String: String]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        app: String = "DontsTool",
        createdAt: Date = Date(),
        files: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.createdAt = createdAt
        self.files = files
    }
}

public enum BackupArchiveService {
    private static let rootFolderName = "DontsToolBackup"
    private static let maximumSafetyBackups = 5
    private static let maximumManifestFileBytes = 25 * 1024 * 1024

    public static func defaultSafetyBackupDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DontsTool/Backups", isDirectory: true)
    }

    @MainActor
    public static func exportArchive(
        to destinationURL: URL,
        settings: SettingsStore,
        websites: WebsiteShortcutStore,
        searchEngines: SearchEngineStore,
        notes: LocalNoteStore
    ) throws {
        guard destinationURL.isFileURL else {
            throw BackupArchiveError.invalidArchive("导出路径无效。")
        }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("dontstool-backup-export-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let bundleRoot = workDir.appendingPathComponent(rootFolderName, isDirectory: true)
        let configsDir = bundleRoot.appendingPathComponent("configs", isDirectory: true)
        try fm.createDirectory(at: configsDir, withIntermediateDirectories: true)

        var fileDigests: [String: String] = [:]

        func writeCheckedFile(_ relativePath: String, data: Data) throws {
            let target = bundleRoot.appendingPathComponent(relativePath, isDirectory: false)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            fileDigests[relativePath] = SyncDigest.sha256Hex(data)
        }

        try writeCheckedFile("configs/settings.json", data: try SyncJSON.makeEncoder().encode(settings.exportSyncedSettings()))
        try writeCheckedFile("configs/websites.json", data: Data(try websites.configuration.json().utf8))
        try writeCheckedFile("configs/search-engines.json", data: Data(try searchEngines.configuration.json().utf8))

        let noteSnapshots = try notes.allNoteSnapshots()
        let noteEncoder = JSONEncoder()
        noteEncoder.outputFormatting = [.sortedKeys]
        for snapshot in noteSnapshots {
            let bucket = snapshot.isTrashed ? "trash" : "active"
            let prefix = "notes/\(bucket)/\(snapshot.record.id.uuidString)"
            try writeCheckedFile("\(prefix)/note.json", data: try noteEncoder.encode(snapshot.record))
            for (assetPath, assetData) in snapshot.assets.sorted(by: { $0.key < $1.key }) {
                try writeCheckedFile("\(prefix)/\(assetPath)", data: assetData)
            }
        }

        let manifest = BackupManifest(files: fileDigests)
        let manifestData = try SyncJSON.makeEncoder().encode(manifest)
        try manifestData.write(to: bundleRoot.appendingPathComponent("manifest.json"), options: .atomic)

        let tempZip = workDir.appendingPathComponent("backup.zip")
        try runProcess("/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", bundleRoot.path, tempZip.path])

        let zipData = try Data(contentsOf: tempZip)
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try zipData.write(to: destinationURL, options: .atomic)
    }

    @MainActor
    public static func restoreArchive(
        from archiveURL: URL,
        safetyBackupDirectory: URL? = nil,
        settings: SettingsStore,
        websites: WebsiteShortcutStore,
        searchEngines: SearchEngineStore,
        notes: LocalNoteStore
    ) throws {
        guard archiveURL.isFileURL else {
            throw BackupArchiveError.invalidArchive("请选择本地 .zip 备份文件。")
        }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("dontstool-backup-restore-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        try validateZipEntries(at: archiveURL)
        let extracted = workDir.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extracted.path])

        let bundleRoot = extracted.appendingPathComponent(rootFolderName, isDirectory: true)
        guard isRegularDirectory(bundleRoot) else {
            throw BackupArchiveError.invalidArchive("缺少 \(rootFolderName) 根目录。")
        }

        let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
        guard isRegularFile(manifestURL),
              let manifestData = try? readBoundedData(manifestURL, maxBytes: 4 * 1024 * 1024),
              let manifest = try? SyncJSON.makeDecoder().decode(BackupManifest.self, from: manifestData),
              manifest.schemaVersion == BackupManifest.currentSchemaVersion,
              manifest.app == "DontsTool" else {
            throw BackupArchiveError.invalidArchive("manifest.json 缺失或版本不受支持。")
        }

        // Verify every file listed in the manifest before decoding any payload.
        for (relativePath, expectedHash) in manifest.files {
            guard isSafeRelativePath(relativePath) else {
                throw BackupArchiveError.invalidArchive("存在不安全路径：\(relativePath)")
            }
            let fileURL = bundleRoot.appendingPathComponent(relativePath, isDirectory: false)
            guard isRegularFile(fileURL) else {
                throw BackupArchiveError.invalidArchive("缺少文件：\(relativePath)")
            }
            let data = try readBoundedData(fileURL, maxBytes: maximumManifestFileBytes)
            guard SyncDigest.sha256Hex(data) == expectedHash else {
                throw BackupArchiveError.invalidArchive("文件校验失败（\(relativePath)）。")
            }
        }

        guard manifest.files["configs/settings.json"] != nil,
              manifest.files["configs/websites.json"] != nil,
              manifest.files["configs/search-engines.json"] != nil else {
            throw BackupArchiveError.invalidArchive("备份包缺少必要配置文件。")
        }

        let settingsData = try Data(contentsOf: bundleRoot.appendingPathComponent("configs/settings.json"))
        let decodedSettings = try SyncJSON.makeDecoder().decode(SettingsStore.SyncedAppSettings.self, from: settingsData)

        let websitesText = String(decoding: try Data(contentsOf: bundleRoot.appendingPathComponent("configs/websites.json")), as: UTF8.self)
        let decodedWebsites = try WebsiteShortcutConfiguration.decode(websitesText)

        let searchText = String(decoding: try Data(contentsOf: bundleRoot.appendingPathComponent("configs/search-engines.json")), as: UTF8.self)
        let decodedSearchEngines = try SearchEngineConfiguration.decode(searchText, reservedKeywords: [])
        let websiteKeywords = Set(decodedWebsites.groups.map(\.keyword))
        let searchReserved = SearchEngineKeywordRules.reservedKeywords(
            current: searchEngines.configuration,
            proposed: decodedSearchEngines,
            websiteKeywords: websiteKeywords
        )
        let validatedSearchEngines = try decodedSearchEngines.validated(reservedKeywords: searchReserved)
        let occupiedBySearch = SearchEngineKeywordRules.reservedWebsiteKeywords(for: validatedSearchEngines)
        if let conflict = decodedWebsites.groups.first(where: { occupiedBySearch.contains($0.keyword) }) {
            throw ActionError.invalidInput("快捷词 \(conflict.keyword) 与搜索引擎冲突。")
        }

        let activeNotes = try parseNotes(in: bundleRoot.appendingPathComponent("notes/active", isDirectory: true), manifest: manifest, prefix: "notes/active/")
        let trashedNotes = try parseNotes(in: bundleRoot.appendingPathComponent("notes/trash", isDirectory: true), manifest: manifest, prefix: "notes/trash/")

        // Take a pre-restore safety snapshot before mutating any live store.
        let safetyDir = safetyBackupDirectory ?? defaultSafetyBackupDirectory()
        try fm.createDirectory(at: safetyDir, withIntermediateDirectories: true)
        let safetyName = "pre-restore-\(timestampTag())-\(UUID().uuidString.prefix(4)).zip"
        try exportArchive(
            to: safetyDir.appendingPathComponent(safetyName),
            settings: settings,
            websites: websites,
            searchEngines: searchEngines,
            notes: notes
        )
        pruneSafetyBackups(in: safetyDir, keep: maximumSafetyBackups)

        let previousSearch = searchEngines.configuration
        try notes.replaceAllNotes(active: activeNotes, trashed: trashedNotes)
        do {
            try searchEngines.save(validatedSearchEngines, reservedKeywords: searchReserved)
            try websites.save(decodedWebsites)
            settings.applySyncedSettings(decodedSettings)
        } catch {
            try? searchEngines.save(previousSearch, reservedKeywords: SearchEngineKeywordRules.reservedKeywords(
                current: previousSearch,
                proposed: previousSearch,
                websiteKeywords: Set(websites.configuration.groups.map(\.keyword))
            ))
            throw error
        }
    }

    private static func parseNotes(
        in directory: URL,
        manifest: BackupManifest,
        prefix: String
    ) throws -> [(LocalNoteRecord, [String: Data])] {
        let fm = FileManager.default
        guard isRegularDirectory(directory) else { return [] }
        var result: [(LocalNoteRecord, [String: Data])] = []
        let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for child in children {
            guard isRegularDirectory(child), let noteID = UUID(uuidString: child.lastPathComponent) else {
                throw BackupArchiveError.invalidArchive("便笺目录结构无效：\(child.lastPathComponent)")
            }
            let noteRel = "\(prefix)\(child.lastPathComponent)/note.json"
            guard manifest.files[noteRel] != nil else {
                throw BackupArchiveError.invalidArchive("便笺记录未在 manifest 中登记：\(noteRel)")
            }
            let recordData = try Data(contentsOf: child.appendingPathComponent("note.json"))
            let record = try JSONDecoder().decode(LocalNoteRecord.self, from: recordData)
            guard record.id == noteID else {
                throw BackupArchiveError.invalidArchive("便笺 ID 与目录不匹配。")
            }
            var assets: [String: Data] = [:]
            let assetsDir = child.appendingPathComponent("assets", isDirectory: true)
            if isRegularDirectory(assetsDir) {
                for assetFile in try fm.contentsOfDirectory(at: assetsDir, includingPropertiesForKeys: nil) {
                    let assetRel = "assets/\(assetFile.lastPathComponent)"
                    let fullRel = "\(prefix)\(child.lastPathComponent)/\(assetRel)"
                    guard manifest.files[fullRel] != nil else {
                        throw BackupArchiveError.invalidArchive("附件未在 manifest 中登记：\(fullRel)")
                    }
                    assets[assetRel] = try Data(contentsOf: assetFile)
                }
            }
            result.append((record, assets))
        }
        return result
    }

    private static func validateZipEntries(at archiveURL: URL) throws {
        let output = try runProcess("/usr/bin/zipinfo", arguments: ["-1", archiveURL.path])
        let entries = output.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty else {
            throw BackupArchiveError.invalidArchive("压缩包为空。")
        }
        for entry in entries {
            guard entry.hasPrefix("\(rootFolderName)/") || entry == "\(rootFolderName)/"
                    || entry.hasPrefix("__MACOSX/\(rootFolderName)/") || entry == "__MACOSX/" || entry == "__MACOSX/\(rootFolderName)" else {
                throw BackupArchiveError.invalidArchive("压缩包包含意外路径：\(entry)")
            }
            let padded = "/\(entry)/"
            guard !padded.contains("/../"), !padded.contains("/./"), !entry.hasPrefix("/") else {
                throw BackupArchiveError.invalidArchive("压缩包包含不安全路径：\(entry)")
            }
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isRegularDirectory(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attrs[.type] as? FileAttributeType == .typeDirectory
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attrs[.type] as? FileAttributeType == .typeRegular
    }

    private static func readBoundedData(_ url: URL, maxBytes: Int) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue >= 0, size.intValue <= maxBytes else {
            throw BackupArchiveError.invalidArchive("文件大小超出限制：\(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else {
            throw BackupArchiveError.invalidArchive("文件大小超出限制：\(url.lastPathComponent)")
        }
        return data
    }

    private static func pruneSafetyBackups(in directory: URL, keep: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let backups = files
            .filter { $0.lastPathComponent.hasPrefix("pre-restore-") && $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for obsolete in backups.dropFirst(keep) {
            try? FileManager.default.removeItem(at: obsolete)
        }
    }

    private static func timestampTag() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    @discardableResult
    private static func runProcess(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackupArchiveError.zipProcessFailed(errText.isEmpty ? "exit \(process.terminationStatus)" : errText)
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
