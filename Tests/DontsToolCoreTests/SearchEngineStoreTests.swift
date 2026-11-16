import Combine
import Foundation
import Testing
@testable import DontsToolCore

@Suite("Search engine store")
@MainActor
struct SearchEngineStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "dontstool.searchtests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test(arguments: ["google", "bing", "baidu", "ddg"])
    func legacyDefaultIsReadWithoutWritingNewConfiguration(_ legacy: String) {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(legacy, forKey: "dontstool.defaultSearchEngine")
        let store = SearchEngineStore(defaults: defaults)
        #expect(store.configuration.defaultEngine.id == legacy)
        #expect(defaults.object(forKey: "dontstool.searchEngines") == nil)
        #expect(store.loadError == nil)
    }

    @Test func savePublishesAndPersistsNormalizedConfiguration() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SearchEngineStore(defaults: defaults)
        var updates: [String] = []
        let subscription = store.$configuration.dropFirst().sink { updates.append($0.defaultEngineID) }
        defer { subscription.cancel() }
        let value = SearchEngineConfiguration(defaultEngineID: "custom", engines: [
            .init(id: "custom", name: " Custom ", keyword: " FIND ", urlTemplate: "https://example.com/{query}")
        ])
        try store.save(value)
        #expect(updates == ["custom"])
        #expect(store.configuration.defaultEngine.keyword == "find")
        #expect(SearchEngineStore(defaults: defaults).configuration == store.configuration)
        #expect(try SearchEngineConfiguration.decode(store.editableJSON).defaultEngine.name == "Custom")
    }

    @Test func invalidSaveAndImportPreserveCurrentConfigurationAndStoredBytes() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SearchEngineStore(defaults: defaults)
        try store.save(.builtIn)
        let original = defaults.data(forKey: "dontstool.searchEngines")
        var invalid = store.configuration
        invalid.defaultEngineID = "missing"
        #expect(throws: (any Error).self) { try store.save(invalid) }
        #expect(throws: (any Error).self) { try store.importJSON("{ broken JSON") }
        #expect(defaults.data(forKey: "dontstool.searchEngines") == original)
        #expect(store.configuration.defaultEngine.id == "google")
    }

    @Test func damagedJSONRemainsExactUntilAnExplicitValidSave() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let original = "\n {\"version\":99,\"notes\":\"请保留原文\"}  \n"
        defaults.set(Data(original.utf8), forKey: "dontstool.searchEngines")
        let store = SearchEngineStore(defaults: defaults)
        #expect(store.loadError != nil)
        #expect(store.editableJSON == original)
        #expect(store.configuration == .builtIn)
        #expect(throws: (any Error).self) { try store.importJSON("bad") }
        #expect(store.editableJSON == original)
        #expect(defaults.data(forKey: "dontstool.searchEngines") == Data(original.utf8))
        try store.importJSON(SearchEngineConfiguration.builtIn.json())
        #expect(store.loadError == nil)
        #expect(try SearchEngineConfiguration.decode(store.editableJSON) == .builtIn)
        #expect(SearchEngineStore(defaults: defaults).loadError == nil)
    }

    @Test func stringBackedDamagedJSONAlsoRemainsEditableWithoutMigration() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let text = "  { invalid stored JSON }\n"
        defaults.set(text, forKey: "dontstool.searchEngines")
        let store = SearchEngineStore(defaults: defaults)
        #expect(store.loadError != nil)
        #expect(store.editableJSON == text)
        #expect(defaults.string(forKey: "dontstool.searchEngines") == text)
    }

    @Test func savedConfigurationTakesPrecedenceOverLegacyDefault() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("bing", forKey: "dontstool.defaultSearchEngine")
        let store = SearchEngineStore(defaults: defaults)
        try store.save(.builtIn)
        #expect(SearchEngineStore(defaults: defaults).configuration.defaultEngineID == "google")
    }
}
