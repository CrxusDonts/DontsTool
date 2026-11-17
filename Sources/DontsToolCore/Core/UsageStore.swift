import Foundation

@MainActor
public final class UsageStore {
    public struct Record: Codable, Equatable, Sendable {
        public var count: Int
        public var lastUsed: Date

        public init(count: Int, lastUsed: Date) {
            self.count = count
            self.lastUsed = lastUsed
        }
    }

    private enum Key {
        static let records = "dontstool.usage.records"
        static let launcherApplicationsOnly = "dontstool.usage.launcherApplicationsOnlyV1"
    }

    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private var records: [String: Record]
    private var flushTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Key.records),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
        if !defaults.bool(forKey: Key.launcherApplicationsOnly) {
            // Old application times mixed launcher opens with unrelated system activations.
            // Counts still identify real launcher opens; their historical order cannot be recovered.
            for (key, var record) in records where key.hasPrefix("/") && URL(fileURLWithPath: key).pathExtension.lowercased() == "app" {
                if record.count > 0 {
                    record.lastUsed = .distantPast
                    records[key] = record
                } else {
                    records.removeValue(forKey: key)
                }
            }
            flush()
            defaults.set(true, forKey: Key.launcherApplicationsOnly)
        }
    }

    public func recordUse(of key: String, at date: Date? = nil) {
        let timestamp = date ?? now()
        var record = records[key] ?? Record(count: 0, lastUsed: timestamp)
        record.count += 1
        record.lastUsed = timestamp
        records[key] = record
        scheduleFlush()
    }

    public func record(for key: String) -> Record? {
        records[key]
    }

    public func boost(for key: String, now date: Date? = nil) -> Double {
        guard let record = records[key] else { return 0 }
        let current = date ?? now()
        let usageBoost = min(100, 15 * log2(1 + Double(record.count)))
        let age = current.timeIntervalSince(record.lastUsed)
        let recencyBoost: Double
        if age <= 86_400 {
            recencyBoost = 50
        } else if age <= 7 * 86_400 {
            recencyBoost = 20
        } else {
            recencyBoost = 0
        }
        return usageBoost + recencyBoost
    }

    public func topKeys(limit: Int) -> [String] {
        records
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                if $0.value.lastUsed != $1.value.lastUsed { return $0.value.lastUsed > $1.value.lastUsed }
                return $0.key < $1.key
            }
            .prefix(limit)
            .map(\.key)
    }

    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Key.records)
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
