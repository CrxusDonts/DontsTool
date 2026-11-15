import Foundation
import Testing
@testable import DontsToolCore

@Suite("CalculatorProvider")
@MainActor
struct CalculatorProviderTests {
    private func makeProvider() -> (CalculatorProvider, SettingsStore, MockClipboard, MockFeedback) {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let clipboard = MockClipboard()
        let feedback = MockFeedback()
        return (CalculatorProvider(settings: settings, clipboard: clipboard, feedback: feedback), settings, clipboard, feedback)
    }

    @Test func globalExpressionShowsResultAndCopiesIt() async throws {
        let (provider, _, clipboard, feedback) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "2 + 3 * 4", mode: .global))

        #expect(items.count == 1)
        #expect(items[0].title == "14")
        #expect(items[0].group == .tool)
        #expect(items[0].primaryAction?.id == "calc.copy")

        try await items[0].primaryAction?.run()
        #expect(clipboard.written == ["14"])
        #expect(feedback.messages == ["已复制 14"])
    }

    @Test func keywordAcceptsUnits() async {
        let (provider, _, _, _) = makeProvider()
        let items = await provider.search(SearchContext(
            rawQuery: "calc 10 km to mi",
            mode: .keyword(providerID: "calculator", keyword: "calc", argument: "10 km to mi")
        ))

        #expect(items.count == 1)
        #expect(items[0].title.hasSuffix(" mi") == true)
    }

    @Test func invalidKeywordInputShowsHintWithoutClosingPanel() async throws {
        let (provider, _, _, feedback) = makeProvider()
        let items = await provider.search(SearchContext(
            rawQuery: "calc nope",
            mode: .keyword(providerID: "calculator", keyword: "calc", argument: "nope")
        ))

        #expect(items.count == 1)
        #expect(items[0].primaryAction?.presentation == .keepPanelOpen)
        try await items[0].primaryAction?.run()
        #expect(feedback.messages == ["请输入算式或单位换算，例如 12 km to mi"])
    }

    @Test func ignoresEmptyQueryAndPlainText() async {
        let (provider, _, _, _) = makeProvider()
        #expect(await provider.search(SearchContext(rawQuery: "", mode: .global)).isEmpty)
        #expect(await provider.search(SearchContext(rawQuery: "Safari", mode: .global)).isEmpty)
    }

    @Test func disabledProviderReturnsNothing() async {
        let (provider, settings, _, _) = makeProvider()
        settings.setProviderEnabled("calculator", to: false)
        let items = await provider.search(SearchContext(rawQuery: "2+2", mode: .global))
        #expect(items.isEmpty)
    }
}
