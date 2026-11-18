import Combine
import Foundation

public enum LocalNoteError: LocalizedError {
    case missingNote
    case invalidContent
    case invalidAsset
    case unsafePath
    case invalidImage
    case imageTooLarge
    case unsupportedVersion
    case exportAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .missingNote: "便笺不存在或已移入最近删除。"
        case .invalidContent: "便笺正文无效或超过大小限制。"
        case .invalidAsset: "图片附件不存在或引用无效。"
        case .unsafePath: "便笺路径无效，不能读取或写入。"
        case .invalidImage: "图片格式不支持或文件已损坏。"
        case .imageTooLarge: "图片不能超过 20 MB 或 3200 万像素。"
        case .unsupportedVersion: "便笺版本不受支持，原始文件已保留。"
        case .exportAlreadyExists: "导出目录已存在，请选择新目录。"
        }
    }
}

public struct NoteSyncSnapshot: Equatable, Sendable {
    public let record: LocalNoteRecord
    public let isTrashed: Bool
    public let assets: [String: Data]

    public init(record: LocalNoteRecord, isTrashed: Bool, assets: [String: Data]) {
        self.record = record
        self.isTrashed = isTrashed
        self.assets = assets
    }
}

@MainActor
public final class LocalNoteStore: ObservableObject {
    @Published public private(set) var notes: [LocalNoteRecord] = []
    @Published public private(set) var trashedNotes: [LocalNoteRecord] = []
    @Published public private(set) var loadError: String?

    public let rootURL: URL
    let fileManager = FileManager.default
    let storageValidator: LocalNoteStorageValidator
    var trashURL: URL { rootURL.appendingPathComponent("Trash", isDirectory: true) }

    public init(rootURL: URL? = nil) {
        self.rootURL = (rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DontsTool/Notes", isDirectory: true)).standardizedFileURL
        self.storageValidator = LocalNoteStorageValidator(fileManager: fileManager)
        do {
            try storageValidator.ensureDirectory(self.rootURL)
            try storageValidator.ensureDirectory(trashURL)
            notes = try storageValidator.loadRecords(in: self.rootURL) { appendLoadError($0) }
            trashedNotes = try storageValidator.loadRecords(in: trashURL) { appendLoadError($0) }
            sortRecords()
        } catch {
            appendLoadError(error)
        }
    }

    @discardableResult
    public func create(title: String? = nil, content: LocalNoteContent = .empty) throws -> LocalNoteRecord {
        try storageValidator.validateDirectory(rootURL)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initialTitle = trimmed.isEmpty
            ? (content == .empty ? "未命名便笺" : automaticTitle(content.plainText))
            : String(trimmed.prefix(80))
        let record = LocalNoteRecord(title: initialTitle, titleIsAutomatic: trimmed.isEmpty, content: content)
        let directory = rootURL.appendingPathComponent(record.id.uuidString, isDirectory: true)
        guard !storageValidator.pathExists(directory) else { throw LocalNoteError.unsafePath }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            _ = try storageValidator.validateContent(content, in: directory)
            try storageValidator.writeRecord(record, in: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        insertActiveNote(record)
        return record
    }

    public static func dailyNoteTitle(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "速记 · %04d-%02d-%02d", year, month, day)
    }

    @discardableResult
    public func appendQuickCapture(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws -> LocalNoteRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalNoteError.invalidContent }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let timeString = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        let dailyTitle = Self.dailyNoteTitle(for: now, calendar: calendar)
        if let existing = notes.first(where: { !$0.titleIsAutomatic && $0.title == dailyTitle }) {
            let updated = existing.content.appending(entry: trimmed, timestamp: timeString)
            return try updateContent(existing.id, content: updated)
        }
        let initial = LocalNoteContent.empty.appending(entry: trimmed, timestamp: timeString)
        return try create(title: dailyTitle, content: initial)
    }

    public func note(_ id: UUID) -> LocalNoteRecord? { notes.first { $0.id == id } }

    public func search(_ query: String, limit: Int = 30) -> [LocalNoteRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return [] }
        return Array(notes.lazy.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.content.plainText.localizedStandardContains(query)
        }.prefix(limit))
    }

    @discardableResult
    public func updateContent(_ id: UUID, content: LocalNoteContent) throws -> LocalNoteRecord {
        var record = try requireNote(id)
        _ = try storageValidator.validateContent(content, in: noteDirectory(id))
        record.content = content
        if record.titleIsAutomatic { record.title = automaticTitle(content.plainText) }
        return try save(record)
    }

    @discardableResult
    public func rename(_ id: UUID, title: String) throws -> LocalNoteRecord {
        var record = try requireNote(id)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.titleIsAutomatic = trimmed.isEmpty
        record.title = trimmed.isEmpty ? automaticTitle(record.content.plainText) : String(trimmed.prefix(80))
        return try save(record)
    }

    @discardableResult
    public func setPinned(_ id: UUID, pinned: Bool) throws -> LocalNoteRecord {
        var record = try requireNote(id)
        record.isPinned = pinned
        return try save(record)
    }

    public func trash(_ id: UUID) throws {
        let record = try requireNote(id)
        let source = try checkedNoteDirectory(id)
        try storageValidator.validateDirectory(trashURL)
        let target = trashURL.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !storageValidator.pathExists(target) else { throw LocalNoteError.unsafePath }
        try fileManager.moveItem(at: source, to: target)
        notes.removeAll { $0.id == id }
        trashedNotes.append(record)
        sortRecords()
    }

    public func deletePermanently(_ id: UUID) throws {
        guard trashedNotes.contains(where: { $0.id == id }) else { throw LocalNoteError.missingNote }
        try storageValidator.validateDirectory(trashURL)
        let target = trashURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try storageValidator.validateDirectory(target)
        try fileManager.removeItem(at: target)
        trashedNotes.removeAll { $0.id == id }
    }

    @discardableResult
    public func restore(_ id: UUID) throws -> LocalNoteRecord {
        guard let record = trashedNotes.first(where: { $0.id == id }) else { throw LocalNoteError.missingNote }
        try storageValidator.validateDirectory(rootURL)
        try storageValidator.validateDirectory(trashURL)
        let source = trashURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try storageValidator.validateDirectory(source)
        let target = noteDirectory(id)
        guard !storageValidator.pathExists(target) else { throw LocalNoteError.unsafePath }
        try fileManager.moveItem(at: source, to: target)
        trashedNotes.removeAll { $0.id == id }
        notes.append(record)
        sortRecords()
        return record
    }

    public func importImage(_ data: Data, for id: UUID) throws -> LocalNoteAsset {
        _ = try requireNote(id)
        let format = try storageValidator.validateImage(data)
        let directory = try checkedNoteDirectory(id)
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try storageValidator.ensureDirectory(assets)
        let relativePath = "assets/\(UUID().uuidString).\(format.fileExtension)"
        let target = directory.appendingPathComponent(relativePath)
        guard !storageValidator.pathExists(target) else { throw LocalNoteError.unsafePath }
        try data.write(to: target, options: .atomic)
        return LocalNoteAsset(relativePath: relativePath, mimeType: format.mimeType)
    }

    public func importImageFile(_ url: URL, for id: UUID) throws -> LocalNoteAsset {
        _ = try requireNote(id)
        guard url.isFileURL else { throw LocalNoteError.unsafePath }
        let data = try storageValidator.readRegularFile(
            url,
            maximumBytes: LocalNoteStorageValidator.maximumImageBytes,
            oversizedError: .imageTooLarge
        )
        return try importImage(data, for: id)
    }

    public func copyImage(from sourceID: UUID, relativePath: String, to targetID: UUID) throws -> LocalNoteAsset {
        let source = try assetURL(for: sourceID, relativePath: relativePath)
        let data = try storageValidator.readRegularFile(
            source,
            maximumBytes: LocalNoteStorageValidator.maximumImageBytes,
            oversizedError: .imageTooLarge
        )
        return try importImage(data, for: targetID)
    }

    public func assetURL(for id: UUID, relativePath: String) throws -> URL {
        _ = try requireNote(id)
        return try storageValidator.checkedAssetURL(in: checkedNoteDirectory(id), relativePath: relativePath)
    }

    func requireNote(_ id: UUID) throws -> LocalNoteRecord {
        guard let record = note(id) else { throw LocalNoteError.missingNote }
        return record
    }

    func noteDirectory(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    func checkedNoteDirectory(_ id: UUID) throws -> URL {
        try storageValidator.validateDirectory(rootURL)
        let directory = noteDirectory(id)
        try storageValidator.validateDirectory(directory)
        return directory
    }

    func insertActiveNote(_ record: LocalNoteRecord) {
        notes.append(record)
        sortRecords()
    }

    func applySyncedRecord(_ record: LocalNoteRecord, isTrashed: Bool) {
        notes.removeAll { $0.id == record.id }
        trashedNotes.removeAll { $0.id == record.id }
        if isTrashed { trashedNotes.append(record) }
        else { notes.append(record) }
        sortRecords()
    }

    func removeSyncedRecord(_ id: UUID) {
        notes.removeAll { $0.id == id }
        trashedNotes.removeAll { $0.id == id }
    }

    func reloadNotesAfterReplace() throws {
        loadError = nil
        notes = try storageValidator.loadRecords(in: rootURL) { appendLoadError($0) }
        trashedNotes = try storageValidator.loadRecords(in: trashURL) { appendLoadError($0) }
        sortRecords()
    }

    func automaticTitle(_ plainText: String) -> String {
        let line = plainText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return line.map { String($0.prefix(80)) } ?? "未命名便笺"
    }

    private func save(_ original: LocalNoteRecord) throws -> LocalNoteRecord {
        var record = original
        record.updatedAt = Date()
        let directory = try checkedNoteDirectory(record.id)
        try storageValidator.writeRecord(record, in: directory)
        if let index = notes.firstIndex(where: { $0.id == record.id }) { notes[index] = record }
        sortRecords()
        return record
    }

    private func appendLoadError(_ error: any Error) {
        let message = error.localizedDescription
        loadError = loadError.map { $0 + "\n" + message } ?? message
    }

    private func sortRecords() {
        func sorted(_ lhs: LocalNoteRecord, _ rhs: LocalNoteRecord) -> Bool {
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        notes.sort(by: sorted)
        trashedNotes.sort(by: sorted)
    }
}
