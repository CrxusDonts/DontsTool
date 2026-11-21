import Foundation
import Testing
@testable import DontsToolCore

@Suite("PluginSourceStore")
@MainActor
struct PluginSourceStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "PluginSourceStoreTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func exposesOfficialBuiltInSourceAndProtectsFromRemoval() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PluginSourceStore(defaults: defaults)
        #expect(store.sources.count == 1)
        let official = store.sources[0]
        #expect(official.isBuiltIn)
        #expect(official.location == "CrxusDonts/DontsTool-Plugins")
        #expect(official.name == "DontsTool 官方插件仓库")
        #expect(official.parsedLocation == .gitHubRepo(owner: "CrxusDonts", repo: "DontsTool-Plugins"))

        let removed = store.removeSource(id: official.id)
        #expect(!removed)
        #expect(store.sources.count == 1)
    }

    @Test func normalizesGitHubReposAndCatalogURLsAndPersistsCustomSources() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(try PluginSourceStore.normalizeLocation("alice/my-plugins") == "alice/my-plugins")
        #expect(try PluginSourceStore.normalizeLocation("https://github.com/alice/my-plugins/") == "alice/my-plugins")
        #expect(try PluginSourceStore.normalizeLocation("https://github.com/alice/my-plugins.git") == "alice/my-plugins")
        #expect(try PluginSourceStore.normalizeLocation("github.com/alice/my-plugins") == "alice/my-plugins")
        #expect(
            try PluginSourceStore.normalizeLocation("https://github.com/alice/my-plugins/releases/latest/download/catalog.json")
                == "https://github.com/alice/my-plugins/releases/latest/download/catalog.json"
        )
        #expect(
            try PluginSourceStore.normalizeLocation("https://plugins.example.com/catalog.json")
                == "https://plugins.example.com/catalog.json"
        )

        let store = PluginSourceStore(defaults: defaults)
        let addedRepo = try store.addSource(location: "https://github.com/alice/my-plugins.git", name: "Alice 插件集")
        #expect(addedRepo.location == "alice/my-plugins")
        #expect(addedRepo.name == "Alice 插件集")
        #expect(!addedRepo.isBuiltIn)

        let addedURL = try store.addSource(location: "https://plugins.example.com/catalog.json")
        #expect(addedURL.location == "https://plugins.example.com/catalog.json")
        #expect(addedURL.name == "plugins.example.com")
        #expect(store.sources.count == 3)

        // Reload from UserDefaults to confirm persistence
        let reloaded = PluginSourceStore(defaults: defaults)
        #expect(reloaded.sources.count == 3)
        #expect(reloaded.sources[1].location == "alice/my-plugins")
        #expect(reloaded.sources[1].name == "Alice 插件集")
        #expect(reloaded.sources[2].location == "https://plugins.example.com/catalog.json")

        // Removal persists
        #expect(reloaded.removeSource(id: addedRepo.id))
        let afterRemove = PluginSourceStore(defaults: defaults)
        #expect(afterRemove.sources.count == 2)
        #expect(!afterRemove.sources.contains { $0.location == "alice/my-plugins" })
    }

    @Test func rejectsInvalidLocationsAndDuplicates() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PluginSourceStore(defaults: defaults)

        for invalid in [
            "",
            "   ",
            "only-one-segment",
            "../evil/repo",
            "http://example.com/catalog.json",
            "file:///tmp/catalog.json",
            "https://github.com/only-owner"
        ] {
            #expect(throws: PluginSourceError.invalidLocation(invalid)) {
                try store.addSource(location: invalid)
            }
        }

        // Duplicate against built-in official source (case-insensitive)
        #expect(throws: PluginSourceError.duplicateSource("crxusdonts/dontstool-plugins")) {
            try store.addSource(location: "https://github.com/crxusdonts/dontstool-plugins")
        }

        _ = try store.addSource(location: "bob/tools")
        #expect(throws: PluginSourceError.duplicateSource("BOB/TOOLS")) {
            try store.addSource(location: "BOB/TOOLS")
        }
    }
}
