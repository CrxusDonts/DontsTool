import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

@MainActor
public final class LocalNoteStore: ObservableObject {
    @Published public private(set) var notes: [LocalNoteRecord] = []
    @Published public private(set) var trashedNotes: [LocalNoteRecord] = []
    @Published public private(set) var loadError: String?

    public let rootURL: URL
    private let fileManager = FileManager.default
    private static let maximumImageBytes = 20 * 1024 * 1024
    private static let maximumPixels = 32_000_000
    private static let maximumTextBytes = 4 * 1024 * 1024
    private static let maximumRecordBytes = 16 * 1024 * 1024
    private var trashURL: URL { rootURL.appendingPathComponent("Trash", isDirectory: true) }

    public init(rootURL: URL? = nil) {
        self.rootURL = (rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DontsTool/Notes", isDirectory: true)).standardizedFileURL
        do {
            try ensureDirectory(self.rootURL)
            try ensureDirectory(trashURL)
            notes = try loadRecords(in: self.rootURL)
            trashedNotes = try loadRecords(in: trashURL)
            sortRecords()
        } catch {
            appendLoadError(error)
        }
    }

    @discardableResult
    public func create(title: String? = nil) throws -> LocalNoteRecord {
        try validateDirectory(rootURL)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let record = LocalNoteRecord(title: trimmed.isEmpty ? "未命名便笺" : String(trimmed.prefix(80)), titleIsAutomatic: trimmed.isEmpty)
        let directory = rootURL.appendingPathComponent(record.id.uuidString, isDirectory: true)
        guard !pathExists(directory) else { throw LocalNoteError.unsafePath }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try writeRecord(record, in: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        notes.append(record)
        sortRecords()
        return record
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
        _ = try validateContent(content, in: noteDirectory(id))
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
        try validateDirectory(trashURL)
        let target = trashURL.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !pathExists(target) else { throw LocalNoteError.unsafePath }
        try fileManager.moveItem(at: source, to: target)
        notes.removeAll { $0.id == id }
        trashedNotes.append(record)
        sortRecords()
    }

    @discardableResult
    public func restore(_ id: UUID) throws -> LocalNoteRecord {
        guard let record = trashedNotes.first(where: { $0.id == id }) else { throw LocalNoteError.missingNote }
        try validateDirectory(rootURL)
        try validateDirectory(trashURL)
        let source = trashURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try validateDirectory(source)
        let target = noteDirectory(id)
        guard !pathExists(target) else { throw LocalNoteError.unsafePath }
        try fileManager.moveItem(at: source, to: target)
        trashedNotes.removeAll { $0.id == id }
        notes.append(record)
        sortRecords()
        return record
    }

    public func importImage(_ data: Data, for id: UUID) throws -> LocalNoteAsset {
        _ = try requireNote(id)
        let format = try validateImage(data)
        let directory = try checkedNoteDirectory(id)
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try ensureDirectory(assets)
        let relativePath = "assets/\(UUID().uuidString).\(format.fileExtension)"
        let target = directory.appendingPathComponent(relativePath)
        guard !pathExists(target) else { throw LocalNoteError.unsafePath }
        try data.write(to: target, options: .atomic)
        return LocalNoteAsset(relativePath: relativePath, mimeType: format.mimeType)
    }

    public func importImageFile(_ url: URL, for id: UUID) throws -> LocalNoteAsset {
        _ = try requireNote(id)
        guard url.isFileURL else { throw LocalNoteError.unsafePath }
        let data = try readRegularFile(url, maximumBytes: Self.maximumImageBytes, oversizedError: .imageTooLarge)
        return try importImage(data, for: id)
    }

    public func copyImage(from sourceID: UUID, relativePath: String, to targetID: UUID) throws -> LocalNoteAsset {
        let source = try assetURL(for: sourceID, relativePath: relativePath)
        let data = try readRegularFile(source, maximumBytes: Self.maximumImageBytes, oversizedError: .imageTooLarge)
        return try importImage(data, for: targetID)
    }

    public func assetURL(for id: UUID, relativePath: String) throws -> URL {
        _ = try requireNote(id)
        return try checkedAssetURL(in: checkedNoteDirectory(id), relativePath: relativePath)
    }

    @discardableResult
    public func exportMarkdown(_ id: UUID, content: LocalNoteContent? = nil, to directory: URL) throws -> URL {
        let record = try requireNote(id)
        let content = content ?? record.content
        let sourceDirectory = try checkedNoteDirectory(id)
        let paths = try validateContent(content, in: sourceDirectory)
        guard directory.isFileURL else { throw LocalNoteError.unsafePath }
        let directory = directory.standardizedFileURL
        guard !pathExists(directory) else { throw LocalNoteError.exportAlreadyExists }
        // Build beside the destination so a failed copy never leaves a partial export.
        let parent = directory.deletingLastPathComponent()
        try validateDirectory(parent)
        let staging = parent.appendingPathComponent(".donts-note-export-\(UUID())", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        try content.markdown.write(to: staging.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        if !paths.isEmpty {
            try fileManager.createDirectory(at: staging.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: false)
            for path in paths.sorted() {
                let source = try checkedAssetURL(in: sourceDirectory, relativePath: path)
                let data = try readRegularFile(source, maximumBytes: Self.maximumImageBytes, oversizedError: .imageTooLarge)
                try data.write(to: staging.appendingPathComponent(path), options: .atomic)
            }
        }
        try fileManager.moveItem(at: staging, to: directory)
        return directory
    }

    private func requireNote(_ id: UUID) throws -> LocalNoteRecord {
        guard let record = note(id) else { throw LocalNoteError.missingNote }
        return record
    }

    private func noteDirectory(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func checkedNoteDirectory(_ id: UUID) throws -> URL {
        try validateDirectory(rootURL)
        let directory = noteDirectory(id)
        try validateDirectory(directory)
        return directory
    }

    private func save(_ original: LocalNoteRecord) throws -> LocalNoteRecord {
        var record = original
        record.updatedAt = Date()
        let directory = try checkedNoteDirectory(record.id)
        try writeRecord(record, in: directory)
        if let index = notes.firstIndex(where: { $0.id == record.id }) { notes[index] = record }
        sortRecords()
        return record
    }

    private func writeRecord(_ record: LocalNoteRecord, in directory: URL) throws {
        try validateDirectory(directory)
        let url = directory.appendingPathComponent("note.json")
        if pathExists(url) { try validateRegularFile(url) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw LocalNoteError.invalidContent }
        try data.write(to: url, options: .atomic)
    }

    private func loadRecords(in directory: URL) throws -> [LocalNoteRecord] {
        try validateDirectory(directory)
        var records: [LocalNoteRecord] = []
        for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            do {
                try validateDirectory(child)
                let data = try readRegularFile(child.appendingPathComponent("note.json"), maximumBytes: Self.maximumRecordBytes, oversizedError: .invalidContent)
                let record = try JSONDecoder().decode(LocalNoteRecord.self, from: data)
                guard record.schemaVersion == LocalNoteRecord.currentSchemaVersion else { throw LocalNoteError.unsupportedVersion }
                guard record.id == id, !record.title.isEmpty, record.title.count <= 80 else { throw LocalNoteError.invalidContent }
                _ = try validateContent(record.content, in: child)
                records.append(record)
            } catch {
                appendLoadError(error)
            }
        }
        return records
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

    private func automaticTitle(_ plainText: String) -> String {
        let line = plainText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return line.map { String($0.prefix(80)) } ?? "未命名便笺"
    }

    private func validateContent(_ content: LocalNoteContent, in directory: URL) throws -> Set<String> {
        guard content.json.utf8.count <= Self.maximumTextBytes,
              content.markdown.utf8.count <= Self.maximumTextBytes,
              content.plainText.utf8.count <= Self.maximumTextBytes,
              let data = content.json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "doc" else { throw LocalNoteError.invalidContent }
        var paths: Set<String> = []
        var count = 0
        func visit(_ value: Any, depth: Int) throws {
            count += 1
            guard depth <= 64, count <= 100_000 else { throw LocalNoteError.invalidContent }
            if let object = value as? [String: Any] {
                if object["type"] as? String == "image" {
                    guard let attrs = object["attrs"] as? [String: Any], let path = attrs["src"] as? String else {
                        throw LocalNoteError.invalidAsset
                    }
                    _ = try checkedAssetURL(in: directory, relativePath: path)
                    paths.insert(path)
                }
                for child in object.values { try visit(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { try visit(child, depth: depth + 1) }
            }
        }
        try visit(root, depth: 0)
        return paths
    }

    private func checkedAssetURL(in directory: URL, relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "assets" else { throw LocalNoteError.invalidAsset }
        let name = String(parts[1])
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard UUID(uuidString: stem) != nil, ["png", "jpg", "gif", "webp"].contains(ext), name == "\(stem).\(ext)" else {
            throw LocalNoteError.invalidAsset
        }
        try validateDirectory(directory)
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try validateDirectory(assets)
        let url = assets.appendingPathComponent(name)
        try validateRegularFile(url)
        return url
    }

    private func ensureDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw LocalNoteError.unsafePath }
        if pathExists(url) { try validateDirectory(url) }
        else { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    private func pathExists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func validateDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw LocalNoteError.unsafePath }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw LocalNoteError.unsafePath }
    }

    private func validateRegularFile(_ url: URL) throws {
        guard url.isFileURL else { throw LocalNoteError.unsafePath }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LocalNoteError.unsafePath }
    }

    private func readRegularFile(_ url: URL, maximumBytes: Int, oversizedError: LocalNoteError) throws -> Data {
        try validateRegularFile(url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= Int64(maximumBytes) else { throw oversizedError }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw oversizedError }
        return data
    }

    private func validateImage(_ data: Data) throws -> (fileExtension: String, mimeType: String) {
        guard !data.isEmpty else { throw LocalNoteError.invalidImage }
        guard data.count <= Self.maximumImageBytes else { throw LocalNoteError.imageTooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw LocalNoteError.invalidImage }
        guard width <= Self.maximumPixels, height <= Self.maximumPixels,
              width <= Self.maximumPixels / height else { throw LocalNoteError.imageTooLarge }
        let format: (fileExtension: String, mimeType: String)
        switch type {
        case UTType.png.identifier: format = ("png", "image/png")
        case UTType.jpeg.identifier: format = ("jpg", "image/jpeg")
        case UTType.gif.identifier: format = ("gif", "image/gif")
        case UTType.webP.identifier: format = ("webp", "image/webp")
        default: throw LocalNoteError.invalidImage
        }
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            throw LocalNoteError.invalidImage
        }
        return format
    }
}
