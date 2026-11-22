import Foundation

/// 在被云端同步覆盖或冲突解决前，自动保存最近的配置本地快照。
@MainActor
public final class SyncConfigHistoryStore {
    public let directoryURL: URL
    private let fileManager: FileManager
    private let maxEntriesPerEntity: Int

    public init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        maxEntriesPerEntity: Int = 10
    ) {
        self.fileManager = fileManager
        self.maxEntriesPerEntity = maxEntriesPerEntity
        if let directoryURL {
            self.directoryURL = directoryURL.standardizedFileURL
        } else {
            self.directoryURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DontsTool/Sync/History", isDirectory: true)
                .standardizedFileURL
        }
    }

    public func recordSnapshot(entityKey: String, json: String, reason: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let entry = SyncConfigHistoryEntry(entityKey: entityKey, savedAt: Date(), reason: reason, json: json)
            let data = try SyncJSON.makeEncoder().encode(entry)
            let sanitizedKey = entityKey.replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: "/", with: "_")
            let ms = Int64(entry.savedAt.timeIntervalSince1970 * 1000)
            let filename = "\(sanitizedKey)-\(ms)-\(entry.id.prefix(8)).json"
            let fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
            try data.write(to: fileURL, options: .atomic)
            pruneOldSnapshots(for: entityKey)
        } catch {
            // 历史快照属于保护性兜底，写入失败不应阻断同步流程。
        }
    }

    public func entries(for entityKey: String? = nil) -> [SyncConfigHistoryEntry] {
        loadFileEntries()
            .filter { entityKey == nil || $0.entry.entityKey == entityKey }
            .map(\.entry)
    }

    private func pruneOldSnapshots(for entityKey: String) {
        let matching = loadFileEntries().filter { $0.entry.entityKey == entityKey }
        guard matching.count > maxEntriesPerEntity else { return }
        for item in matching.dropFirst(maxEntriesPerEntity) {
            try? fileManager.removeItem(at: item.url)
        }
    }

    private func loadFileEntries() -> [(url: URL, entry: SyncConfigHistoryEntry)] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = SyncJSON.makeDecoder()
        var loaded: [(url: URL, entry: SyncConfigHistoryEntry)] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(SyncConfigHistoryEntry.self, from: data) else {
                continue
            }
            loaded.append((url, entry))
        }
        return loaded.sorted {
            if $0.entry.savedAt != $1.entry.savedAt {
                return $0.entry.savedAt > $1.entry.savedAt
            }
            return $0.entry.id > $1.entry.id
        }
    }
}
