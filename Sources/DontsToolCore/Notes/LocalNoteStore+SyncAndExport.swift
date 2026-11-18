import Foundation

extension LocalNoteStore {
    @discardableResult
    public func exportMarkdown(_ id: UUID, content: LocalNoteContent? = nil, to directory: URL) throws -> URL {
        let record = try requireNote(id)
        let content = content ?? record.content
        let sourceDirectory = try checkedNoteDirectory(id)
        let paths = try storageValidator.validateContent(content, in: sourceDirectory)
        guard directory.isFileURL else { throw LocalNoteError.unsafePath }
        let directory = directory.standardizedFileURL
        guard !storageValidator.pathExists(directory) else { throw LocalNoteError.exportAlreadyExists }
        // Build beside the destination so a failed copy never leaves a partial export.
        let parent = directory.deletingLastPathComponent()
        try storageValidator.validateDirectory(parent)
        let staging = parent.appendingPathComponent(".donts-note-export-\(UUID())", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        try content.markdown.write(to: staging.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        if !paths.isEmpty {
            try fileManager.createDirectory(
                at: staging.appendingPathComponent("assets", isDirectory: true),
                withIntermediateDirectories: false
            )
            for path in paths.sorted() {
                let source = try storageValidator.checkedAssetURL(in: sourceDirectory, relativePath: path)
                let data = try storageValidator.readRegularFile(
                    source,
                    maximumBytes: LocalNoteStorageValidator.maximumImageBytes,
                    oversizedError: .imageTooLarge
                )
                try data.write(to: staging.appendingPathComponent(path), options: .atomic)
            }
        }
        try fileManager.moveItem(at: staging, to: directory)
        return directory
    }

    public func allNoteSnapshots() throws -> [NoteSyncSnapshot] {
        var snapshots: [NoteSyncSnapshot] = []
        for record in notes {
            snapshots.append(try snapshot(for: record, in: noteDirectory(record.id), isTrashed: false))
        }
        for record in trashedNotes {
            snapshots.append(try snapshot(for: record, in: trashDirectory(record.id), isTrashed: true))
        }
        return snapshots
    }

    public func noteSnapshot(_ id: UUID) throws -> NoteSyncSnapshot? {
        if let active = notes.first(where: { $0.id == id }) {
            return try snapshot(for: active, in: noteDirectory(id), isTrashed: false)
        }
        if let trashed = trashedNotes.first(where: { $0.id == id }) {
            return try snapshot(for: trashed, in: trashDirectory(id), isTrashed: true)
        }
        return nil
    }

    @discardableResult
    public func createCopy(
        title: String,
        content: LocalNoteContent,
        isPinned: Bool = false,
        assets: [String: Data]
    ) throws -> LocalNoteRecord {
        try storageValidator.validateDirectory(rootURL)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = trimmed.isEmpty ? automaticTitle(content.plainText) : String(trimmed.prefix(80))
        let record = LocalNoteRecord(
            title: normalizedTitle,
            titleIsAutomatic: trimmed.isEmpty,
            isPinned: isPinned,
            content: content
        )
        let directory = noteDirectory(record.id)
        guard !storageValidator.pathExists(directory) else { throw LocalNoteError.unsafePath }
        let staging = fileManager.temporaryDirectory.appendingPathComponent(".donts-note-copy-\(UUID())", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        try stageNote(record, assets: assets, in: staging)
        try fileManager.moveItem(at: staging, to: directory)
        insertActiveNote(record)
        return record
    }

    public func applySyncedNote(_ record: LocalNoteRecord, isTrashed: Bool, assets: [String: Data]) throws {
        try storageValidator.ensureDirectory(rootURL)
        try storageValidator.ensureDirectory(trashURL)
        let staging = fileManager.temporaryDirectory.appendingPathComponent(".donts-note-sync-\(UUID())", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        try stageNote(record, assets: assets, in: staging)

        let target = isTrashed ? trashDirectory(record.id) : noteDirectory(record.id)
        let opposite = isTrashed ? noteDirectory(record.id) : trashDirectory(record.id)
        var backup: URL?
        if storageValidator.pathExists(target) {
            let backupURL = fileManager.temporaryDirectory.appendingPathComponent(".donts-note-backup-\(UUID())", isDirectory: true)
            try fileManager.moveItem(at: target, to: backupURL)
            backup = backupURL
        }
        do {
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            if let backup { try? fileManager.moveItem(at: backup, to: target) }
            throw error
        }
        if let backup { try? fileManager.removeItem(at: backup) }
        if storageValidator.pathExists(opposite) { try? fileManager.removeItem(at: opposite) }

        applySyncedRecord(record, isTrashed: isTrashed)
    }

    public func applySyncedDeletion(_ id: UUID) throws {
        let active = noteDirectory(id)
        let trashed = trashDirectory(id)
        if storageValidator.pathExists(active) {
            try storageValidator.validateDirectory(active)
            try fileManager.removeItem(at: active)
        }
        if storageValidator.pathExists(trashed) {
            try storageValidator.validateDirectory(trashed)
            try fileManager.removeItem(at: trashed)
        }
        removeSyncedRecord(id)
    }

    public func replaceAllNotes(
        active: [(LocalNoteRecord, [String: Data])],
        trashed: [(LocalNoteRecord, [String: Data])]
    ) throws {
        var seen = Set<UUID>()
        for (record, _) in active + trashed {
            guard seen.insert(record.id).inserted else { throw LocalNoteError.invalidContent }
        }

        let stagingRoot = fileManager.temporaryDirectory.appendingPathComponent(".donts-notes-restore-\(UUID())", isDirectory: true)
        let stagingTrash = stagingRoot.appendingPathComponent("Trash", isDirectory: true)
        try fileManager.createDirectory(at: stagingTrash, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        try stageBucket(active, into: stagingRoot)
        try stageBucket(trashed, into: stagingTrash)

        try storageValidator.ensureDirectory(rootURL)
        let rollback = fileManager.temporaryDirectory.appendingPathComponent(".donts-notes-rollback-\(UUID())", isDirectory: true)
        try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
        var movedToRollback: [String] = []

        do {
            for child in try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
                let name = child.lastPathComponent
                guard name == "Trash" || UUID(uuidString: name) != nil else { continue }
                try fileManager.moveItem(at: child, to: rollback.appendingPathComponent(name))
                movedToRollback.append(name)
            }
            for child in try fileManager.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil) {
                try fileManager.moveItem(at: child, to: rootURL.appendingPathComponent(child.lastPathComponent))
            }
            try storageValidator.ensureDirectory(trashURL)
        } catch {
            for child in (try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? [] {
                let name = child.lastPathComponent
                if name == "Trash" || UUID(uuidString: name) != nil {
                    try? fileManager.removeItem(at: child)
                }
            }
            for name in movedToRollback {
                try? fileManager.moveItem(at: rollback.appendingPathComponent(name), to: rootURL.appendingPathComponent(name))
            }
            try? fileManager.removeItem(at: rollback)
            throw error
        }

        try? fileManager.removeItem(at: rollback)
        try reloadNotesAfterReplace()
    }

    private func trashDirectory(_ id: UUID) -> URL {
        trashURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func snapshot(for record: LocalNoteRecord, in directory: URL, isTrashed: Bool) throws -> NoteSyncSnapshot {
        let paths = try storageValidator.validateContent(record.content, in: directory)
        var assets: [String: Data] = [:]
        for path in paths.sorted() {
            let url = try storageValidator.checkedAssetURL(in: directory, relativePath: path)
            assets[path] = try storageValidator.readRegularFile(
                url,
                maximumBytes: LocalNoteStorageValidator.maximumImageBytes,
                oversizedError: .imageTooLarge
            )
        }
        return NoteSyncSnapshot(record: record, isTrashed: isTrashed, assets: assets)
    }

    private func stageBucket(_ entries: [(LocalNoteRecord, [String: Data])], into directory: URL) throws {
        for (record, assets) in entries {
            let noteDir = directory.appendingPathComponent(record.id.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: noteDir, withIntermediateDirectories: false)
            try stageNote(record, assets: assets, in: noteDir)
        }
    }

    private func stageNote(_ record: LocalNoteRecord, assets: [String: Data], in directory: URL) throws {
        guard record.schemaVersion == LocalNoteRecord.currentSchemaVersion,
              !record.title.isEmpty, record.title.count <= 80 else {
            throw LocalNoteError.invalidContent
        }
        if !assets.isEmpty {
            let assetsDir = directory.appendingPathComponent("assets", isDirectory: true)
            try fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: false)
            for (relativePath, data) in assets {
                let (name, ext) = try storageValidator.validatedAssetFilename(for: relativePath)
                let format = try storageValidator.validateImage(data)
                guard format.fileExtension == ext else { throw LocalNoteError.invalidImage }
                try data.write(to: assetsDir.appendingPathComponent(name), options: .atomic)
            }
        }
        _ = try storageValidator.validateContent(record.content, in: directory)
        try storageValidator.writeRecord(record, in: directory)
    }
}
