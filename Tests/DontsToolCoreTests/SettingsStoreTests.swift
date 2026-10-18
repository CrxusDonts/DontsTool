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

    @Test func defaultsAreStable() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "zh")

        #expect(store.hotKey == .optionSpace)
        #expect(store.defaultSearchEngine == .google)
        #expect(store.enabledProviderIDs == Set(ProviderID.allCases.map(\.rawValue)))
        #expect(store.fileSearchEnabled)
        #expect(store.translationTarget == "zh-Hans")
        #expect(!store.hasCompletedOnboarding)
        #expect(store.knowledgeBaseURL.isEmpty)
    }

    @Test func changesPersist() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "en")

        store.setHotKey(.init(keyCode: 1, modifiers: 2048))
        store.setDefaultSearchEngine(.bing)
        store.setProviderEnabled(ProviderID.web.rawValue, to: false)
        store.setFileSearchEnabled(false)
        store.setTranslationTarget("ja")
        store.setKnowledgeBaseURL("https://kb.example.com")
        store.completeOnboarding()

        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloaded.hotKey == .init(keyCode: 1, modifiers: 2048))
        #expect(reloaded.defaultSearchEngine == .bing)
        #expect(!reloaded.isProviderEnabled(ProviderID.web.rawValue))
        #expect(!reloaded.fileSearchEnabled)
        #expect(reloaded.translationTarget == "ja")
        #expect(reloaded.hasCompletedOnboarding)
        #expect(reloaded.knowledgeBaseURL == "https://kb.example.com")
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
    func upgradedProviderPreferencesEnableKnowledgeOnceWithoutChangingOldChoices(_ oldEnabled: [String]) {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(oldEnabled, forKey: "dontstool.enabledProviders")

        let migrated = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(migrated.enabledProviderIDs == Set(oldEnabled + ["knowledge"]))
        #expect(Set(defaults.array(forKey: "dontstool.enabledProviders") as? [String] ?? []) == Set(oldEnabled + ["knowledge"]))

        migrated.setProviderEnabled("knowledge", to: false)
        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloaded.enabledProviderIDs == Set(oldEnabled))
        let reloadedAgain = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloadedAgain.enabledProviderIDs == Set(oldEnabled))
    }

    @Test func searchEngineBuildsEncodedURL() {
        let url = SettingsStore.SearchEngine.google.searchURL(for: "swift concurrency + 中文")
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        #expect(components?.host == "www.google.com")
        #expect(components?.queryItems?.first?.value == "swift concurrency + 中文")
    }
}
