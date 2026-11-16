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

    private func scoped(_ query: String = "report") -> SearchContext {
        SearchContext(rawQuery: "file " + query, mode: .keyword(providerID: "file", keyword: "file", argument: query))
    }

    @Test func returnsFileItemsForExplicitQuery() async throws {
        let (provider, _, _, _, _) = makeProvider()
        let items = await provider.search(scoped())
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.title == "report.pdf")
        #expect(item.group == .file)
        #expect(item.score > 0)
        #expect(item.primaryAction?.id == "file.open")
        #expect(item.secondaryAction?.id == "file.reveal")
        #expect(provider.statusNotice == nil)
    }

    @Test(arguments: ["report", "微信", "/tmp/report.pdf", "~/Desktop/report.pdf", "https://example.com"])
    func globalQueriesNeverStartFileCommands(_ query: String) async {
        let (provider, _, _, _, runner) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: query, mode: .global))
        #expect(items.isEmpty)
        #expect(runner.receivedArguments.isEmpty)
        #expect(provider.statusNotice == nil)
    }

    @Test(arguments: ["file report", "FILE report", "file   report  "])
    func keywordRoutePassesOnlyTheFilename(_ query: String) async {
        let (provider, _, _, _, runner) = makeProvider()
        let context = QueryParser.parse(query, routes: ToolRegistry(providers: [provider]).enabledKeywordRoutes())
        let items = await provider.search(context)
        #expect(items.count == 1)
        #expect(Array(runner.receivedArguments.prefix(2)) == ["-name", "report"])
    }

    @Test func filenameKeepsInternalSpaces() async {
        let (provider, _, _, _, runner) = makeProvider(output: "/Users/donts/Desktop/project report.pdf\n")
        let context = QueryParser.parse("file project report", routes: ToolRegistry(providers: [provider]).enabledKeywordRoutes())
        let items = await provider.search(context)
        #expect(items.first?.title == "project report.pdf")
        #expect(Array(runner.receivedArguments.prefix(2)) == ["-name", "project report"])
    }

    @Test(arguments: ["", "  ", "\t\n"])
    func emptyExplicitArgumentsNeverStartFileCommands(_ argument: String) async {
        let (provider, _, _, _, runner) = makeProvider()
        #expect(await provider.search(scoped(argument)).isEmpty)
        #expect(runner.receivedArguments.isEmpty)
    }

    @Test func disabledProviderCannotSearchExplicitly() async {
        let (provider, settings, _, _, runner) = makeProvider()
        settings.setProviderEnabled(provider.id, to: false)
        #expect(await provider.search(scoped()).isEmpty)
        #expect(runner.receivedArguments.isEmpty)
    }

    @Test func globalCoordinatorSkipsBothCommandsAndSlowStatus() async {
        let (provider, _, _, _, runner) = makeProvider()
        let app = MockProvider(id: "app", searchHandler: { _ in [makeItem(group: .app, canonicalKey: "app")] })
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [app, provider]), slowDelay: .zero)
        var updates: [SearchCoordinator.Update] = []
        coordinator.onUpdate = { updates.append($0) }
        coordinator.submit("report")
        await coordinator.waitForPendingSearch()
        #expect(runner.receivedArguments.isEmpty)
        #expect(updates.count == 1)
        #expect(updates.last?.status == .idle)
        #expect(updates.last?.items.map(\.group) == [.app])
    }

    @Test func explicitCoordinatorNeverFallsBackToWebAndBareKeywordStartsNoCommand() async {
        let (provider, _, _, _, runner) = makeProvider(output: "")
        let web = MockProvider(id: "web", searchHandler: { _ in [makeItem(group: .web, canonicalKey: "web")] })
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [provider, web]), slowDelay: .zero)
        var last: SearchCoordinator.Update?
        coordinator.onUpdate = { last = $0 }
        coordinator.submit("file")
        await coordinator.waitForPendingSearch()
        #expect(runner.receivedArguments.isEmpty)
        #expect(last?.status == .idle)
        coordinator.submit("file missing")
        await coordinator.waitForPendingSearch()
        #expect(Array(runner.receivedArguments.prefix(2)) == ["-name", "missing"])
        #expect(web.receivedQueries.isEmpty)
        #expect(last?.items.isEmpty == true)
    }

    @Test func fullPathStillOpensThroughQuickOpenWithoutSpotlight() async throws {
        let (files, settings, launcher, feedback, runner) = makeProvider()
        let suite = "dontstool.quickopen.file-mode.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let quickOpen = QuickOpenProvider(settings: settings, usage: UsageStore(defaults: defaults),
            launcher: launcher, opener: MockURLOpener(), clipboard: MockClipboard(), feedback: feedback,
            fileExists: { $0 == "/tmp/report.pdf" })
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [files, quickOpen]), slowDelay: .zero)
        var updates: [SearchCoordinator.Update] = []
        coordinator.onUpdate = { updates.append($0) }
        coordinator.submit("/tmp/report.pdf")
        await coordinator.waitForPendingSearch()
        #expect(updates.count == 1)
        #expect(updates.last?.status == .idle)
        let item = try #require(updates.last?.items.first)
        try await item.primaryAction?.run()
        #expect(launcher.openedFiles.map(\.path) == ["/tmp/report.pdf"])
        #expect(runner.receivedArguments.isEmpty)
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
        let (provider, settings, _, _, runner) = makeProvider()
        settings.setFileSearchEnabled(false)
        let items = await provider.search(scoped())
        #expect(items.isEmpty)
        #expect(runner.receivedArguments.isEmpty)
    }

    @Test func timeoutWithNoResultsSetsNotice() async {
        let (provider, _, _, _, _) = makeProvider(output: "", timedOut: true)
        let items = await provider.search(scoped())
        #expect(items.isEmpty)
        #expect(provider.statusNotice == "文件搜索超时")
    }

    @Test func timeoutWithPartialResultsSetsNotice() async {
        let (provider, _, _, _, _) = makeProvider(output: "/Users/donts/Desktop/report.pdf\n", timedOut: true)
        let items = await provider.search(scoped())
        #expect(items.count == 1)
        #expect(provider.statusNotice == "文件搜索较慢，已显示部分结果")
    }

    @Test func commandFailureSetsNotice() async {
        let (provider, _, _, _, _) = makeProvider(commandError: ActionError.commandFailed("boom"))
        let items = await provider.search(scoped())
        #expect(items.isEmpty)
        #expect(provider.statusNotice == "文件搜索不可用")
    }

    @Test func openActionOpensFileAndRecordsUsage() async throws {
        let (provider, _, launcher, feedback, _) = makeProvider()
        let items = await provider.search(scoped())
        let item = try #require(items.first)
        try await item.primaryAction?.run()
        #expect(launcher.openedFiles.map(\.lastPathComponent) == ["report.pdf"])
        #expect(feedback.messages.isEmpty)
    }

    @Test func revealActionRevealsInFinder() async throws {
        let (provider, _, launcher, _, _) = makeProvider()
        let items = await provider.search(scoped())
        let item = try #require(items.first)
        try await item.fileAction(.reveal)?.run()
        #expect(launcher.revealed.map(\.lastPathComponent) == ["report.pdf"])
    }

    @Test func copyPathActionWritesFullFilePath() async throws {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let runner = MockCommandRunner()
        runner.result = CommandResult(output: "/Users/donts/Desktop/report.pdf\n", terminationStatus: 0, timedOut: false)
        let clipboard = MockClipboard()
        let provider = FileProvider(
            settings: SettingsStore(defaults: defaults, systemLanguageCode: "en"),
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback(),
            service: FileSearchService(runner: runner),
            clipboard: clipboard
        )

        let items = await provider.search(scoped())
        let item = try #require(items.first)
        #expect(item.actions.map(\.id) == ["file.open", "file.reveal", "file.copyPath"])
        try await item.fileAction(.copyPath)?.run()
        #expect(clipboard.written == ["/Users/donts/Desktop/report.pdf"])
    }
}
