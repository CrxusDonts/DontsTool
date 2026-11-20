import Foundation
import Testing
@testable import DontsToolCore

@Suite("FeatureGuide & HelpGuideProvider")
@MainActor
struct FeatureGuideTests {
    private final class SpyPrefill: QueryPrefilling {
        var values: [String] = []
        func prefill(_ query: String) { values.append(query) }
    }

    @Test func catalogCoversCoreBuiltInProvidersAndSupportsKeywordSearch() {
        let entries = FeatureGuideCatalog.entries
        #expect(entries.count >= 12)
        #expect(entries.contains { $0.id == "chrome" })
        #expect(entries.contains { $0.id == "terminal-finder" })
        #expect(entries.contains { $0.id == "kill-process" })
        #expect(entries.contains { $0.id == "notes" })

        let portMatches = FeatureGuideCatalog.entries(matching: "端口")
        #expect(portMatches.first?.id == "kill-process")

        let ghosttyMatches = FeatureGuideCatalog.entries(matching: "otty")
        #expect(ghosttyMatches.first?.id == "terminal-finder")

        let shortcuts = FeatureGuideCatalog.shortcutRows(hotKeyDisplay: "⌥Space")
        #expect(shortcuts.first?.keyCap == "⌥Space")
    }

    @Test func helpProviderStaysSilentOnEmptyGlobalAndSearchesGuideOnKeyword() async throws {
        var openedQueries: [String] = []
        let prefill = SpyPrefill()
        let provider = HelpGuideProvider(
            openGuide: { openedQueries.append($0) },
            prefill: prefill
        )

        #expect(provider.homeToolEntry() == nil)
        #expect(await provider.search(SearchContext(rawQuery: "", mode: .global)).isEmpty)

        let globalItems = await provider.search(SearchContext(rawQuery: "帮助", mode: .global))
        #expect(globalItems.count == 1)
        try await globalItems.first?.primaryAction?.run()
        #expect(openedQueries == [""])

        let portHelp = await provider.search(SearchContext(
            rawQuery: "help 端口",
            mode: .keyword(providerID: provider.id, keyword: "help", argument: "端口")
        ))
        let killEntry = try #require(portHelp.first { $0.canonicalKey == "help-guide:entry:kill-process" })
        try await killEntry.secondaryAction?.run()
        #expect(prefill.values == ["kill "])

        try await killEntry.primaryAction?.run()
        #expect(openedQueries.last == "端口")
    }

    @Test func helpProviderYieldsConflictingKeywords() {
        let provider = HelpGuideProvider(openGuide: { _ in }, unavailableKeywords: { ["help", "?"] })
        #expect(!provider.keywords.contains("help"))
        #expect(!provider.keywords.contains("?"))
        #expect(provider.keywords.contains("帮助"))
    }
}
