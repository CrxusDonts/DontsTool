import Foundation
import Testing
@testable import DontsToolCore

@Suite("FileProvider")
@MainActor
struct FileProviderTests {
    private func makeProvider(
        output: String = "/Users/donts/Desktop/report.pdf\n",
        terminationStatus: Int32 = 0,
        timedOut: Bool = false,
        commandError: Error? = nil
    ) -> (FileProvider, SettingsStore, MockAppLauncher, MockFeedback, MockCommandRunner) {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let launcher = MockAppLauncher()
        let feedback = MockFeedback()
        let runner = MockCommandRunner()
        runner.result = CommandResult(output: output, terminationStatus: terminationStatus, timedOut: timedOut)
        runner.error = commandError
        let provider = FileProvider(
            settings: settings,
            usage: UsageStore(defaults: defaults),
            launcher: launcher,
            feedback: feedback,
            service: FileSearchService(runner: runner)
        )
        return (provider, settings, launcher, feedback, runner)
    }

    @Test func returnsFileItemsForGlobalQuery() async {
        let (provider, _, _, _, _) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "report", mode: .global))
        #expect(items.count == 1)
        #expect(items[0].title == "report.pdf")
        #expect(items[0].group == .file)
        #expect(items[0].score > 0)
        #expect(items[0].primaryAction?.id == "file.open")
        #expect(items[0].secondaryAction?.id == "file.reveal")
        #expect(provider.statusNotice == nil)
    }

    @Test func emptyQueryDoesNotSearch() async {
        let (provider, _, _, _, runner) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(items.isEmpty)
        #expect(runner.receivedArguments.isEmpty)
    }

    @Test func keywordModeIsIgnored() async {
        let (provider, _, _, _, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "g report",
            mode: .keyword(providerID: "web", keyword: "g", argument: "report")
        )
        let items = await provider.search(context)
        #expect(items.isEmpty)
    }

    @Test func disabledFileSearchReturnsNothing() async {
        let (provider, settings, _, _, _) = makeProvider()
        settings.setFileSearchEnabled(false)
        let items = await provider.search(SearchContext(rawQuery: "report", mode: .global))
        #expect(items.isEmpty)
    }

    @Test func timeoutWithNoResultsSetsNotice() async {
        let (provider, _, _, _, _) = makeProvider(output: "", timedOut: true)
        let items = await provider.search(SearchContext(rawQuery: "report", mode: .global))
        #expect(items.isEmpty)
        #expect(provider.statusNotice == "文件搜索超时")
    }

    @Test func timeoutWithPartialResultsSetsNotice() async {
        let (provider, _, _, _, _) = makeProvider(output: "/Users/donts/Desktop/report.pdf\n", timedOut: true)
        let items = await provider.search(SearchContext(rawQuery: "report", mode: .global))
        #expect(items.count == 1)
        #expect(provider.statusNotice == "文件搜索较慢，已显示部分结果")
    }

    @Test func commandFailureSetsNotice() async {
        let (provider, _, _, _, _) = makeProvider(commandError: ActionError.commandFailed("boom"))
        let items = await provider.search(SearchContext(rawQuery: "report", mode: .global))
        #expect(items.isEmpty)
        #expect(provider.statusNotice == "文件搜索不可用")
    }

    @Test func openActionOpensFileAndRecordsUsage() async throws {
        let (provider, _, launcher, feedback, _) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "report", mode: .global))
        try await items[0].primaryAction?.run()
        #expect(launcher.openedFiles.map(\.lastPathComponent) == ["report.pdf"])
        #expect(feedback.messages.isEmpty)
    }

    @Test func revealActionRevealsInFinder() async throws {
        let (provider, _, launcher, _, _) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "report", mode: .global))
        try await items[0].secondaryAction?.run()
        #expect(launcher.revealed.map(\.lastPathComponent) == ["report.pdf"])
    }
}
