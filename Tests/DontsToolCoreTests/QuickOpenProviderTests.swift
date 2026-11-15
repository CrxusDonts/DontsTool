import Foundation
import Testing
@testable import DontsToolCore

@Suite("QuickOpenProvider")
@MainActor
struct QuickOpenProviderTests {
    private func makeProvider(
        fileExists: @escaping (String) -> Bool = { _ in false }
    ) -> (QuickOpenProvider, SettingsStore, MockAppLauncher, MockURLOpener, MockClipboard, MockFeedback) {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let launcher = MockAppLauncher()
        let opener = MockURLOpener()
        let clipboard = MockClipboard()
        let feedback = MockFeedback()
        let provider = QuickOpenProvider(
            settings: settings,
            usage: UsageStore(defaults: defaults),
            launcher: launcher,
            opener: opener,
            clipboard: clipboard,
            feedback: feedback,
            fileExists: fileExists
        )
        return (provider, settings, launcher, opener, clipboard, feedback)
    }

    @Test func opensURLAndCopiesLink() async throws {
        let (provider, _, _, opener, clipboard, _) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "https://example.com/docs", mode: .global))

        #expect(items.count == 1)
        #expect(items[0].primaryAction?.id == "quickopen.url.open")
        try await items[0].primaryAction?.run()
        #expect(opener.opened.map(\.absoluteString) == ["https://example.com/docs"])

        try await items[0].actions.first(where: { $0.id == "quickopen.url.copy" })?.run()
        #expect(clipboard.written == ["https://example.com/docs"])
    }

    @Test func opensExistingFilePath() async throws {
        let (provider, _, launcher, _, clipboard, _) = makeProvider(fileExists: { $0 == "/tmp/report.pdf" })
        let items = await provider.search(SearchContext(rawQuery: "/tmp/report.pdf", mode: .global))

        #expect(items.count == 1)
        #expect(items[0].title == "打开 report.pdf")
        #expect(items[0].primaryAction?.id == "quickopen.file.open")
        #expect(items[0].actions.map(\.id) == ["quickopen.file.open", "quickopen.file.reveal", "quickopen.file.copy"])

        try await items[0].primaryAction?.run()
        #expect(launcher.openedFiles.map(\.path) == ["/tmp/report.pdf"])

        try await items[0].secondaryAction?.run()
        #expect(launcher.revealed.map(\.path) == ["/tmp/report.pdf"])
        #expect(launcher.openedFiles.count == 1)

        try await items[0].actions.last?.run()
        #expect(clipboard.written == ["/tmp/report.pdf"])
    }

    @Test func keywordModeUsesArgument() async {
        let (provider, _, _, _, _, _) = makeProvider()
        let items = await provider.search(SearchContext(
            rawQuery: "open https://example.com",
            mode: .keyword(providerID: "quickOpen", keyword: "open", argument: "https://example.com")
        ))
        #expect(items.count == 1)
        #expect(items[0].title == "打开网址")
    }

    @Test func emptyKeywordShowsHint() async throws {
        let (provider, _, _, _, _, feedback) = makeProvider()
        let items = await provider.search(SearchContext(
            rawQuery: "open",
            mode: .keyword(providerID: "quickOpen", keyword: "open", argument: "")
        ))

        #expect(items.count == 1)
        #expect(items[0].primaryAction?.presentation == .keepPanelOpen)
        try await items[0].primaryAction?.run()
        #expect(feedback.messages == ["请输入网址或已存在的绝对路径"])
    }

    @Test func ignoresPlainTextAndEmptyQuery() async {
        let (provider, _, _, _, _, _) = makeProvider()
        #expect(await provider.search(SearchContext(rawQuery: "", mode: .global)).isEmpty)
        #expect(await provider.search(SearchContext(rawQuery: "Safari", mode: .global)).isEmpty)
    }

    @Test func disabledProviderReturnsNothing() async {
        let (provider, settings, _, _, _, _) = makeProvider()
        settings.setProviderEnabled("quickOpen", to: false)
        let items = await provider.search(SearchContext(rawQuery: "https://example.com", mode: .global))
        #expect(items.isEmpty)
    }
}
