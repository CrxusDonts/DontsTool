import Foundation
import Testing
@testable import DontsToolCore

@Suite("SettingsStore")
@MainActor
struct SettingsStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "dontstool.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test(arguments: SelectionHoldDelay.allCases)
    func holdDelayPersists(_ delay: SelectionHoldDelay) {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        store.setSelectionHoldDelay(delay)
        #expect(store.selectionHoldDelay == delay)
        #expect(SettingsStore(defaults: defaults).selectionHoldDelay == delay)
    }

    @Test func unknownHoldDelayUsesExistingTwoSecondDefault() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-1, forKey: "dontstool.selectionHoldDelay")
        #expect(SettingsStore(defaults: defaults).selectionHoldDelay == .seconds2)
    }

    @Test func defaultsAreStable() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "zh")

        #expect(store.hotKey == .optionSpace)
        #expect(store.enabledProviderIDs == Set(ProviderID.allCases.map(\.rawValue)))
        #expect(store.fileSearchEnabled)
        #expect(store.translationTarget == "zh-Hans")
        #expect(!store.selectionTranslationEnabled)
        #expect(!store.hasCompletedOnboarding)
    }

    @Test func changesPersist() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "en")

        store.setHotKey(.init(keyCode: 1, modifiers: 2048))
        store.setProviderEnabled(ProviderID.web.rawValue, to: false)
        store.setFileSearchEnabled(false)
        store.setTranslationTarget("ja")
        store.setSelectionTranslationEnabled(true)
        store.completeOnboarding()

        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloaded.hotKey == .init(keyCode: 1, modifiers: 2048))
        #expect(!reloaded.isProviderEnabled(ProviderID.web.rawValue))
        #expect(!reloaded.fileSearchEnabled)
        #expect(reloaded.translationTarget == "ja")
        #expect(reloaded.selectionTranslationEnabled)
        #expect(reloaded.hasCompletedOnboarding)
    }

    @Test func doubleTapHotKeyPersists() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "zh")

        store.setHotKey(.doubleTap(.option))

        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        #expect(reloaded.hotKey.kind == .doubleTap)
        #expect(reloaded.hotKey.doubleTapModifier == .option)
    }

    @Test func disablingAllProvidersPersistsEmptySet() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        for id in ProviderID.allCases {
            store.setProviderEnabled(id.rawValue, to: false)
        }

        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloaded.enabledProviderIDs.isEmpty)
    }

    @Test(arguments: [[], ["app"], ["app", "web"]])
    func upgradedProviderPreferencesEnableNewBuiltInsOnceWithoutChangingOldChoices(_ oldEnabled: [String]) {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(oldEnabled, forKey: "dontstool.enabledProviders")

        let newBuiltIns = ["calculator", "quickOpen", "gemini", "ideaProjects", "notes"]
        let migrated = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(migrated.enabledProviderIDs == Set(oldEnabled + newBuiltIns))
        #expect(Set(defaults.array(forKey: "dontstool.enabledProviders") as? [String] ?? []) == Set(oldEnabled + newBuiltIns))

        migrated.setProviderEnabled("calculator", to: false)
        migrated.setProviderEnabled("gemini", to: false)
        migrated.setProviderEnabled("ideaProjects", to: false)
        migrated.setProviderEnabled("notes", to: false)
        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloaded.enabledProviderIDs == Set(oldEnabled + ["quickOpen"]))
        let reloadedAgain = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloadedAgain.enabledProviderIDs == Set(oldEnabled + ["quickOpen"]))
    }

    @Test func notesMigrationEnablesOnlyNotesAndRespectsLaterDisable() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["app"], forKey: "dontstool.enabledProviders")
        for key in ["builtInProviderDefaultsV2Completed", "applicationWorkflowsMigrationCompleted"] {
            defaults.set(true, forKey: "dontstool." + key)
        }
        let migrated = SettingsStore(defaults: defaults)
        #expect(migrated.enabledProviderIDs == ["app", "notes"])
        migrated.setProviderEnabled("notes", to: false)
        #expect(SettingsStore(defaults: defaults).enabledProviderIDs == ["app"])
    }

    @Test func legacyKnowledgePreferencesAreIgnoredAndCleanedOnLoad() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["app", "knowledge", "notes"], forKey: "dontstool.enabledProviders")
        defaults.set("https://kb.example.com", forKey: "dontstool.knowledgeBaseURL")
        for key in [
            "knowledgeProviderMigrationCompleted",
            "builtInProviderDefaultsV2Completed",
            "applicationWorkflowsMigrationCompleted",
            "notesProviderMigrationCompleted"
        ] {
            defaults.set(true, forKey: "dontstool." + key)
        }
        let store = SettingsStore(defaults: defaults)
        #expect(store.enabledProviderIDs == ["app", "notes"])
    }

    @Test func applicationSortDefaultsToRecentUse() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(store.applicationSortOrder == .recent)
    }

    @Test(arguments: ["recent", "frequency", "name"])
    func applicationSortOrderPersists(rawOrder: String) throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let order = try #require(SettingsStore.ApplicationSortOrder(rawValue: rawOrder))
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "en")

        store.setApplicationSortOrder(order)

        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloaded.applicationSortOrder == order)
        #expect(defaults.string(forKey: "dontstool.applicationSortOrder") == rawOrder)
    }

    @Test func invalidApplicationSortOrderFallsBackToRecentUse() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unavailable", forKey: "dontstool.applicationSortOrder")
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(store.applicationSortOrder == .recent)
    }
}
