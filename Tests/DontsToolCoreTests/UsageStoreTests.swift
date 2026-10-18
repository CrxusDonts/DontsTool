import Foundation
import Testing
@testable import DontsToolCore

@Suite("UsageStore")
@MainActor
struct UsageStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "dontstool.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func recordsCountAndBoost() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(defaults: defaults, now: { now })

        store.recordUse(of: "/Applications/Chrome.app", at: now)
        store.recordUse(of: "/Applications/Chrome.app", at: now)

        #expect(store.record(for: "/Applications/Chrome.app")?.count == 2)
        let expected = 15 * log2(1.0 + 2.0) + 50.0
        #expect(abs(store.boost(for: "/Applications/Chrome.app", now: now) - expected) < 0.001)
    }

    @Test func oldUseHasNoRecencyBoost() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-8 * 86_400)
        let store = UsageStore(defaults: defaults, now: { now })
        store.recordUse(of: "x", at: old)
        #expect(abs(store.boost(for: "x", now: now) - 15 * log2(2.0)) < 0.001)
    }

    @Test func flushPersistsRecords() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(defaults: defaults, now: { now })
        store.recordUse(of: "a", at: now)
        store.recordUse(of: "b", at: now.addingTimeInterval(1))
        store.flush()

        let reloaded = UsageStore(defaults: defaults, now: { now })
        #expect(reloaded.record(for: "a")?.count == 1)
        #expect(reloaded.record(for: "b")?.count == 1)
    }

    @Test func topKeysSortsRecentFirst() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(defaults: defaults, now: { now })
        store.recordUse(of: "older", at: now.addingTimeInterval(-100))
        store.recordUse(of: "newer", at: now)
        #expect(store.topKeys(limit: 2) == ["newer", "older"])
    }
}
