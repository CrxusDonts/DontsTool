import Foundation
import Testing
@testable import DontsToolCore

@Suite("翻译窗口入口") @MainActor
struct TranslationProviderTests {
    @Test func openTranslationAndRespectServiceSwitch() async throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let opener = MockToolOpener()
        let provider = TranslationProvider(settings: settings, toolOpener: opener)
        let items = await provider.search(SearchContext(rawQuery: "tr hello", mode: .keyword(providerID: "translation", keyword: "tr", argument: "hello")))
        #expect(items.count == 1)
        try await items[0].primaryAction?.run()
        #expect(opener.requests.first?.kind == .translation)
        #expect(opener.requests.first?.input == "hello")
        provider.isEnabled = false
        #expect(await provider.search(SearchContext(rawQuery: "", mode: .global)).isEmpty)
    }
}
