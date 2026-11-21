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

        let newBuiltIns = ["calculator", "quickOpen", "gemini", "ideaProjects", "notes", "killProcess", "chrome", "terminalFinder"]
        let migrated = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(migrated.enabledProviderIDs == Set(oldEnabled + newBuiltIns))
        #expect(Set(defaults.array(forKey: "dontstool.enabledProviders") as? [String] ?? []) == Set(oldEnabled + newBuiltIns))

        migrated.setProviderEnabled("calculator", to: false)
        migrated.setProviderEnabled("gemini", to: false)
        migrated.setProviderEnabled("ideaProjects", to: false)
        migrated.setProviderEnabled("notes", to: false)
        migrated.setProviderEnabled("killProcess", to: false)
        migrated.setProviderEnabled("chrome", to: false)
        migrated.setProviderEnabled("terminalFinder", to: false)
        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloaded.enabledProviderIDs == Set(oldEnabled + ["quickOpen"]))
        let reloadedAgain = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloadedAgain.enabledProviderIDs == Set(oldEnabled + ["quickOpen"]))
    }

    @Test func notesMigrationEnablesOnlyNotesAndRespectsLaterDisable() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["app"], forKey: "dontstool.enabledProviders")
        for key in [
            "builtInProviderDefaultsV2Completed",
            "applicationWorkflowsMigrationCompleted",
            "killProcessProviderMigrationCompleted",
            "chromeProviderMigrationCompleted",
            "terminalFinderProviderMigrationCompleted"
        ] {
            defaults.set(true, forKey: "dontstool." + key)
        }
        let migrated = SettingsStore(defaults: defaults)
        #expect(migrated.enabledProviderIDs == ["app", "notes"])
        migrated.setProviderEnabled("notes", to: false)
        #expect(SettingsStore(defaults: defaults).enabledProviderIDs == ["app"])
    }

    @Test func killProcessMigrationEnablesOnlyKillProcessAndRespectsLaterDisable() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["app"], forKey: "dontstool.enabledProviders")
        for key in [
            "builtInProviderDefaultsV2Completed",
            "applicationWorkflowsMigrationCompleted",
            "notesProviderMigrationCompleted",
            "chromeProviderMigrationCompleted",
            "terminalFinderProviderMigrationCompleted"
        ] {
            defaults.set(true, forKey: "dontstool." + key)
        }
        let migrated = SettingsStore(defaults: defaults)
        #expect(migrated.enabledProviderIDs == ["app", "killProcess"])
        migrated.setProviderEnabled("killProcess", to: false)
        #expect(SettingsStore(defaults: defaults).enabledProviderIDs == ["app"])
    }

    @Test func chromeMigrationEnablesOnlyChromeAndRespectsLaterDisable() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["app"], forKey: "dontstool.enabledProviders")
        for key in [
            "builtInProviderDefaultsV2Completed",
            "applicationWorkflowsMigrationCompleted",
            "notesProviderMigrationCompleted",
            "killProcessProviderMigrationCompleted",
            "terminalFinderProviderMigrationCompleted"
        ] {
            defaults.set(true, forKey: "dontstool." + key)
        }
        let migrated = SettingsStore(defaults: defaults)
        #expect(migrated.enabledProviderIDs == ["app", "chrome"])
        migrated.setProviderEnabled("chrome", to: false)
        #expect(SettingsStore(defaults: defaults).enabledProviderIDs == ["app"])
    }

    @Test func terminalFinderMigrationEnablesOnlyTerminalFinderAndPersistsPreferredTerminal() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["app"], forKey: "dontstool.enabledProviders")
        for key in [
            "builtInProviderDefaultsV2Completed",
            "applicationWorkflowsMigrationCompleted",
            "notesProviderMigrationCompleted",
            "killProcessProviderMigrationCompleted",
            "chromeProviderMigrationCompleted"
        ] {
            defaults.set(true, forKey: "dontstool." + key)
        }
        let migrated = SettingsStore(defaults: defaults)
        #expect(migrated.enabledProviderIDs == ["app", "terminalFinder"])
        migrated.setProviderEnabled("terminalFinder", to: false)
        migrated.setPreferredTerminalBundleID(TerminalAppCatalog.ghosttyBundleID)
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.enabledProviderIDs == ["app"])
        #expect(reloaded.preferredTerminalBundleID == TerminalAppCatalog.ghosttyBundleID)
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
            "notesProviderMigrationCompleted",
            "killProcessProviderMigrationCompleted",
            "chromeProviderMigrationCompleted",
            "terminalFinderProviderMigrationCompleted"
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

    @Test func aiAPIFormatDefaultsPersistsAndMaintainsLegacyCloudSyncCompatibility() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        #expect(store.aiAPIFormat == .openAIResponses)

        for format in AIAPIFormat.allCases {
            store.setAIAPIFormat(format)
            #expect(store.aiAPIFormat == format)
            #expect(SettingsStore(defaults: defaults, systemLanguageCode: "zh").aiAPIFormat == format)
        }

        // Invalid stored value falls back to default .openAIResponses
        defaults.set("unknown_format", forKey: "dontstool.aiAPIFormat")
        #expect(SettingsStore(defaults: defaults, systemLanguageCode: "zh").aiAPIFormat == .openAIResponses)

        // Export & re-apply SyncedAppSettings round-trips aiAPIFormat
        store.setAIAPIFormat(.gemini)
        let exported = store.exportSyncedSettings()
        #expect(exported.aiAPIFormat == "gemini")

        let (defaults2, name2) = makeDefaults()
        defer { defaults2.removePersistentDomain(forName: name2) }
        let targetStore = SettingsStore(defaults: defaults2, systemLanguageCode: "zh")
        targetStore.applySyncedSettings(exported)
        #expect(targetStore.aiAPIFormat == .gemini)

        // Legacy cloud sync / backup JSON without aiAPIFormat decodes cleanly and preserves existing format
        let legacyJSON = """
        {
          "hotKey": { "kind": "combination", "keyCode": 49, "modifiers": 2048 },
          "applicationSortOrder": "recent",
          "enabledProviderIDs": ["app", "translation"],
          "fileSearchEnabled": true,
          "translationTarget": "zh-Hans",
          "translationAPIBaseURL": "https://api.openai.com/v1",
          "translationAPIModel": "gpt-4.1-mini",
          "selectionHoldDelayRawValue": 2,
          "selectionTranslationEnabled": false
        }
        """
        let legacyDecoded = try JSONDecoder().decode(SettingsStore.SyncedAppSettings.self, from: Data(legacyJSON.utf8))
        #expect(legacyDecoded.aiAPIFormat == nil)
        #expect(legacyDecoded.aiModelProfiles == nil)
        targetStore.applySyncedSettings(legacyDecoded)
        #expect(targetStore.aiAPIFormat == .gemini)
    }

    @Test func legacySingleConfigAutoMigratesToProfileAndPreservesKeychainFallback() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("https://api.openai.com/v1", forKey: "dontstool.translationAPIBaseURL")
        defaults.set("gpt-4.1-mini", forKey: "dontstool.translationAPIModel")
        defaults.set("openai_responses", forKey: "dontstool.aiAPIFormat")

        let secrets = MemorySecretStore()
        secrets.setSecret("sk-legacy-only", for: SecretAccount.translationAPIKey)

        let store = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        #expect(store.aiModelProfiles.count == 1)
        let migrated = store.aiModelProfiles[0]
        #expect(migrated.id == SettingsStore.legacyMigratedProfileID)
        #expect(migrated.name == "gpt-4.1-mini")
        #expect(migrated.format == .openAIResponses)
        #expect(migrated.baseURL == "https://api.openai.com/v1")
        #expect(migrated.model == "gpt-4.1-mini")
        #expect(store.defaultAIModelProfileID == SettingsStore.legacyMigratedProfileID)

        // Legacy keychain fallback works seamlessly for both profile and resolved config
        let resolved = store.resolvedAIConfiguration(for: .quickAI)
        #expect(resolved.profileID == SettingsStore.legacyMigratedProfileID)
        #expect(store.apiKey(for: resolved, secrets: secrets) == "sk-legacy-only")
        #expect(store.apiKey(for: migrated, secrets: secrets) == "sk-legacy-only")

        // Saving a new key on legacy-default keeps translationAPIKey in sync
        store.saveAPIKey("sk-updated-legacy", for: migrated, secrets: secrets)
        #expect(secrets.secret(for: migrated.secretAccount) == "sk-updated-legacy")
        #expect(secrets.secret(for: SecretAccount.translationAPIKey) == "sk-updated-legacy")

        // Deleting migrated profile clears both keychain keys and does NOT resurrect on reload
        store.deleteAIModelProfile(id: SettingsStore.legacyMigratedProfileID, secrets: secrets)
        #expect(store.aiModelProfiles.isEmpty)
        #expect(store.defaultAIModelProfileID == nil)
        #expect(secrets.secret(for: migrated.secretAccount) == nil)
        #expect(secrets.secret(for: SecretAccount.translationAPIKey) == nil)

        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        #expect(reloaded.aiModelProfiles.isEmpty)
        #expect(reloaded.defaultAIModelProfileID == nil)
    }

    @Test func multiProfileCRUDSceneBindingsAndDeletionFallback() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = MemorySecretStore()
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "zh")

        let gemini = AIModelProfile(
            id: "prof-gemini",
            name: "Gemini Flash",
            format: .gemini,
            baseURL: " https://generativelanguage.googleapis.com/v1beta ",
            model: " gemini-2.5-flash "
        )
        let openai = AIModelProfile(
            id: "prof-openai",
            name: "   ",
            format: .openAIResponses,
            baseURL: "http://localhost:11434/v1",
            model: "gpt-4.1-mini"
        )

        store.upsertAIModelProfile(gemini)
        store.upsertAIModelProfile(openai)
        store.saveAPIKey("AIza-gemini-key", for: gemini, secrets: secrets)
        store.saveAPIKey("sk-openai-key", for: openai, secrets: secrets)

        #expect(store.aiModelProfiles.count == 2)
        #expect(store.aiModelProfile(id: "prof-gemini")?.displayHost == "generativelanguage.googleapis.com")
        #expect(store.aiModelProfile(id: "prof-openai")?.displayHost == "localhost:11434")
        #expect(store.aiModelProfile(id: "prof-openai")?.name == "gpt-4.1-mini")
        #expect(store.defaultAIModelProfileID == "prof-gemini")

        // Bind translation -> Gemini, quickAI -> OpenAI
        store.setTranslationAIModelProfileID("prof-gemini")
        store.setQuickAIAIModelProfileID("prof-openai")

        let transConfig = store.resolvedAIConfiguration(for: .translation)
        let quickConfig = store.resolvedAIConfiguration(for: .quickAI)
        #expect(transConfig.profileID == "prof-gemini")
        #expect(transConfig.format == .gemini)
        #expect(transConfig.displaySummary == "Gemini Flash · gemini-2.5-flash")
        #expect(store.apiKey(for: transConfig, secrets: secrets) == "AIza-gemini-key")

        #expect(quickConfig.profileID == "prof-openai")
        #expect(quickConfig.format == .openAIResponses)
        #expect(store.apiKey(for: quickConfig, secrets: secrets) == "sk-openai-key")

        // Legacy fields reflect active .translation config
        #expect(store.translationAPIBaseURL == "https://generativelanguage.googleapis.com/v1beta")
        #expect(store.translationAPIModel == "gemini-2.5-flash")
        #expect(store.aiAPIFormat == .gemini)

        // Persist and reload
        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        #expect(reloaded.aiModelProfiles.count == 2)
        #expect(reloaded.defaultAIModelProfileID == "prof-gemini")
        #expect(reloaded.translationAIModelProfileID == "prof-gemini")
        #expect(reloaded.quickAIAIModelProfileID == "prof-openai")

        // Deleting default & translation-bound profile auto-repairs bindings and clears its keychain key
        reloaded.deleteAIModelProfile(id: "prof-gemini", secrets: secrets)
        #expect(reloaded.aiModelProfiles.map(\.id) == ["prof-openai"])
        #expect(reloaded.defaultAIModelProfileID == "prof-openai")
        #expect(reloaded.translationAIModelProfileID == nil)
        #expect(reloaded.quickAIAIModelProfileID == "prof-openai")
        #expect(secrets.secret(for: gemini.secretAccount) == nil)
        #expect(secrets.secret(for: openai.secretAccount) == "sk-openai-key")
        #expect(reloaded.resolvedAIConfiguration(for: .translation).profileID == "prof-openai")
        #expect(reloaded.translationAPIModel == "gpt-4.1-mini")
        #expect(reloaded.aiAPIFormat == .openAIResponses)
    }
}
