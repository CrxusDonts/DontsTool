import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Validates note AST payloads, image assets, and symlink-safe filesystem paths.
@MainActor
struct LocalNoteStorageValidator {
    static let maximumImageBytes = 20 * 1024 * 1024
    static let maximumPixels = 32_000_000
    static let maximumTextBytes = 4 * 1024 * 1024
    static let maximumRecordBytes = 16 * 1024 * 1024

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func writeRecord(_ record: LocalNoteRecord, in directory: URL) throws {
        try validateDirectory(directory)
        let url = directory.appendingPathComponent("note.json")
        if pathExists(url) { try validateRegularFile(url) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw LocalNoteError.invalidContent }
        try data.write(to: url, options: .atomic)
    }

    func loadRecords(in directory: URL, onError: @MainActor (any Error) -> Void) throws -> [LocalNoteRecord] {
        try validateDirectory(directory)
        var records: [LocalNoteRecord] = []
        for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            do {
                try validateDirectory(child)
                let data = try readRegularFile(
                    child.appendingPathComponent("note.json"),
                    maximumBytes: Self.maximumRecordBytes,
                    oversizedError: .invalidContent
                )
                let record = try JSONDecoder().decode(LocalNoteRecord.self, from: data)
                guard record.schemaVersion == LocalNoteRecord.currentSchemaVersion else {
                    throw LocalNoteError.unsupportedVersion
                }
                guard record.id == id, !record.title.isEmpty, record.title.count <= 80 else {
                    throw LocalNoteError.invalidContent
                }
                _ = try validateContent(record.content, in: child)
                records.append(record)
            } catch {
                onError(error)
            }
        }
        return records
    }

    func validateContent(_ content: LocalNoteContent, in directory: URL) throws -> Set<String> {
        guard content.json.utf8.count <= Self.maximumTextBytes,
              content.markdown.utf8.count <= Self.maximumTextBytes,
              content.plainText.utf8.count <= Self.maximumTextBytes,
              let data = content.json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "doc" else {
            throw LocalNoteError.invalidContent
        }
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

    func validatedAssetFilename(for relativePath: String) throws -> (name: String, fileExtension: String) {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "assets" else { throw LocalNoteError.invalidAsset }
        let name = String(parts[1])
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard UUID(uuidString: stem) != nil,
              ["png", "jpg", "gif", "webp"].contains(ext),
              name == "\(stem).\(ext)" else {
            throw LocalNoteError.invalidAsset
        }
        return (name, ext)
    }

    func checkedAssetURL(in directory: URL, relativePath: String) throws -> URL {
        let (name, _) = try validatedAssetFilename(for: relativePath)
        try validateDirectory(directory)
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try validateDirectory(assets)
        let url = assets.appendingPathComponent(name)
        try validateRegularFile(url)
        return url
    }

    func ensureDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw LocalNoteError.unsafePath }
        if pathExists(url) { try validateDirectory(url) }
        else { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    func pathExists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    func validateDirectory(_ url: URL) throws {
        try validateItemType(url, expected: .typeDirectory)
    }

    func validateRegularFile(_ url: URL) throws {
        try validateItemType(url, expected: .typeRegular)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int, oversizedError: LocalNoteError) throws -> Data {
        try validateRegularFile(url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value > 0,
              size.int64Value <= Int64(maximumBytes) else {
            throw oversizedError
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw oversizedError }
        return data
    }

    func validateImage(_ data: Data) throws -> (fileExtension: String, mimeType: String) {
        guard !data.isEmpty else { throw LocalNoteError.invalidImage }
        guard data.count <= Self.maximumImageBytes else { throw LocalNoteError.imageTooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw LocalNoteError.invalidImage
        }
        guard width <= Self.maximumPixels, height <= Self.maximumPixels,
              width <= Self.maximumPixels / height else {
            throw LocalNoteError.imageTooLarge
        }
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

    private func validateItemType(_ url: URL, expected: FileAttributeType) throws {
        guard url.isFileURL else { throw LocalNoteError.unsafePath }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == expected else { throw LocalNoteError.unsafePath }
    }
}
