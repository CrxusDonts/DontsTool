import Foundation
import Testing
@testable import DontsToolCore

@Suite("SearchCoordinator")
@MainActor
struct SearchCoordinatorTests {
    private func makeCoordinator(_ providers: [ToolProvider]) -> SearchCoordinator {
        SearchCoordinator(registry: ToolRegistry(providers: providers), slowDelay: .zero)
    }

    private func collect(_ coordinator: SearchCoordinator) -> () -> [SearchCoordinator.Update] {
        var updates: [SearchCoordinator.Update] = []
        coordinator.onUpdate = { updates.append($0) }
        return { updates }
    }

    @Test func defaultToolsFavorLatestThenFrequentOpens() async throws {
        let suite = "dontstool.tool-order.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let opener = MockToolOpener()
        let providers: [ToolProvider] = [
            TextToolsProvider(settings: settings, toolOpener: opener),
            TranslationProvider(settings: settings, toolOpener: opener),
        ]
        let usage = UsageStore(defaults: defaults)
        let frequentDate = Date().addingTimeInterval(-60)
        usage.recordUse(of: "tool:base64", at: frequentDate)
        for _ in 0..<4 { usage.recordUse(of: "tool:url", at: frequentDate) }
        usage.recordUse(of: "tool:translation")
        usage.flush()

        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: providers),
                                            usage: UsageStore(defaults: defaults))
        let updates = collect(coordinator)
        coordinator.submit("")
        await coordinator.waitForPendingSearch()
        #expect(updates().last?.items.map(\.canonicalKey) == [
            "tool:translation", "tool:url", "tool:base64", "tool:json", "tool:timestamp", "tool:uuid", "tool:hash",
        ])

        coordinator.submit("编码")
        await coordinator.waitForPendingSearch()
        #expect(updates().last?.items.map(\.canonicalKey) == ["tool:base64", "tool:url"])
    }

    @MainActor
    private final class CoordinatorNoteOpener: LocalNoteOpening {
        func createNote() {}
        func openNote(_ id: UUID) {}
        @discardableResult func quickCapture(_ text: String) throws -> LocalNoteRecord {
            LocalNoteRecord(content: .plainText(text))
        }
    }

    @Test func defaultToolsOrderByMostRecentAndPromoteHomeEntries() async throws {
        let suite = "dontstool.tool-recent.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notesDir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: notesDir) }
        let settings = SettingsStore(defaults: defaults)
        let opener = MockToolOpener()
        let usage = UsageStore(defaults: defaults)
        let notesStore = LocalNoteStore(rootURL: notesDir)
        let notesOpener = CoordinatorNoteOpener()
        let killProvider = KillProcessProvider(settings: settings, usage: usage)
        let providers: [ToolProvider] = [
            NotesProvider(settings: settings, store: notesStore, opener: notesOpener, usage: usage),
            TextToolsProvider(settings: settings, toolOpener: opener),
            TranslationProvider(settings: settings, toolOpener: opener),
            killProvider
        ]

        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: providers), usage: usage)
        let updates = collect(coordinator)

        // 未使用任何工具时，默认 8 个工具填满网格，未用过的 homeToolEntry 不挤占默认工具。
        coordinator.submit("")
        await coordinator.waitForPendingSearch()
        let initialKeys = updates().last?.items.map(\.canonicalKey) ?? []
        #expect(initialKeys.count == 8)
        #expect(!initialKeys.contains(KillProcessProvider.entryCanonicalKey))

        // 按时间先后使用：先高频用 url，再较新用 base64，最后刚用结束进程。
        let now = Date()
        for _ in 0..<5 { usage.recordUse(of: "tool:url", at: now.addingTimeInterval(-300)) }
        usage.recordUse(of: "tool:base64", at: now.addingTimeInterval(-60))
        usage.recordUse(of: KillProcessProvider.entryCanonicalKey, at: now.addingTimeInterval(-10))

        coordinator.submit("")
        await coordinator.waitForPendingSearch()
        let recentKeys = updates().last?.items.map(\.canonicalKey) ?? []
        #expect(recentKeys.count == 8)
        #expect(Array(recentKeys.prefix(3)) == [
            KillProcessProvider.entryCanonicalKey,
            "tool:base64",
            "tool:url"
        ])
    }

    @Test func keywordModeQueriesOnlyTargetProvider() async {
        let app = MockProvider(id: "app")
        let text = MockProvider(
            id: "text",
            keywords: ["json"],
            searchHandler: { _ in [makeItem(providerID: "text", canonicalKey: "json")] }
        )
        let coordinator = makeCoordinator([app, text])
        let updates = collect(coordinator)

        coordinator.submit("JSON {}")
        await coordinator.waitForPendingSearch()

        #expect(app.receivedQueries.isEmpty)
        #expect(text.receivedQueries == ["{}"])
        #expect(updates().last?.items.count == 1)
    }

    @Test func disabledProviderIsExcluded() async {
        let enabled = MockProvider(id: "enabled", searchHandler: { _ in [makeItem(canonicalKey: "a")] })
        let disabled = MockProvider(
            id: "disabled",
            isEnabled: false,
            searchHandler: { _ in [makeItem(canonicalKey: "b")] }
        )
        let coordinator = makeCoordinator([enabled, disabled])
        let updates = collect(coordinator)

        coordinator.submit("query")
        await coordinator.waitForPendingSearch()

        #expect(disabled.receivedQueries.isEmpty)
        #expect(updates().last?.items.map(\.canonicalKey) == ["a"])
    }

    @Test func fastAndSlowResultsMerge() async {
        let fast = MockProvider(id: "fast", searchHandler: { _ in [makeItem(group: .app, title: "App", canonicalKey: "app")] })
        let slow = MockProvider(
            id: "slow",
            phase: .slow,
            searchHandler: { _ in [makeItem(group: .file, title: "File", canonicalKey: "file")] }
        )
        let coordinator = makeCoordinator([fast, slow])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().count == 2)
        #expect(updates().first?.status == .searchingFiles)
        #expect(updates().last?.items.map(\.group) == [.app, .file])
        #expect(updates().last?.status == .idle)
    }

    @Test func duplicateCanonicalKeyKeepsHigherScore() async {
        let first = MockProvider(id: "first", searchHandler: { _ in [makeItem(title: "Low", score: 10, canonicalKey: "same")] })
        let second = MockProvider(id: "second", searchHandler: { _ in [makeItem(title: "High", score: 20, canonicalKey: "same")] })
        let coordinator = makeCoordinator([first, second])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.items.count == 1)
        #expect(updates().last?.items.first?.title == "High")
    }

    @Test func groupsAndCapsAreApplied() async {
        let apps = (0..<10).map { makeItem(group: .app, title: "App\($0)", score: Double(10 - $0), canonicalKey: "app\($0)") }
        let tools = (0..<10).map { makeItem(group: .tool, title: "Tool\($0)", score: Double(10 - $0), canonicalKey: "tool\($0)") }
        let shortcuts = (0..<10).map { makeItem(group: .shortcut, title: "Shortcut\($0)", score: Double(10 - $0), canonicalKey: "shortcut\($0)") }
        let files = [makeItem(group: .file, canonicalKey: "file")]
        let provider = MockProvider(id: "p", searchHandler: { _ in apps + tools + shortcuts + files })
        let coordinator = makeCoordinator([provider])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        let items = updates().last!.items
        #expect(items.filter { $0.group == .app }.count == 8)
        #expect(items.filter { $0.group == .tool }.count == 8)
        #expect(items.first?.group == .app)
        #expect(items[16].group == .file)
        #expect(items.filter { $0.group == .shortcut }.count == 8)
        #expect(items.last?.group == .shortcut)
    }

    @Test func keywordModeAllowsUpToThirtyToolItems() async {
        let tools = (0..<35).map { makeItem(providerID: "killProcess", group: .tool, title: "Proc\($0)", score: Double(100 - $0), canonicalKey: "proc:\($0)") }
        let provider = MockProvider(id: "killProcess", keywords: ["kill"], searchHandler: { _ in tools })
        let coordinator = makeCoordinator([provider])
        let updates = collect(coordinator)

        coordinator.submit("kill")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.items.count == 30)
    }

    @Test func webFallbackIsRemovedWhenLocalResultsExist() async {
        let local = MockProvider(id: "local", searchHandler: { _ in [makeItem(group: .app, canonicalKey: "app")] })
        let web = MockProvider(id: "web", searchHandler: { _ in [makeItem(group: .web, canonicalKey: "web")] })
        let coordinator = makeCoordinator([local, web])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.items.map(\.group) == [.app])
    }

    @Test func webFallbackSurvivesWithoutLocalResults() async {
        let web = MockProvider(id: "web", searchHandler: { _ in [makeItem(group: .web, canonicalKey: "web")] })
        let coordinator = makeCoordinator([web])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.items.map(\.group) == [.web])
    }

    @Test func statusNoticeIsPublished() async {
        let slow = MockProvider(
            id: "file",
            phase: .slow,
            statusNotice: "文件搜索不可用",
            searchHandler: { _ in [] }
        )
        let coordinator = makeCoordinator([slow])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.status == .message("文件搜索不可用"))
    }

    @Test func scopedFastProviderNoticeIsPublishedWithoutSlowProviders() async {
        let fast = MockProvider(id: "notes", keywords: ["note"], statusNotice: "便笺索引需要刷新")
        let coordinator = makeCoordinator([fast])
        let updates = collect(coordinator)

        coordinator.submit("note draft")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.status == .message("便笺索引需要刷新"))
    }

    @Test(arguments: [nil, "文件搜索失败"] as [String?])
    func slowPhaseKeepsFastNoticeUnlessSlowProviderHasItsOwn(_ slowNotice: String?) async {
        let fast = MockProvider(id: "fast", statusNotice: "索引加载失败")
        let slow = MockProvider(id: "file", phase: .slow, statusNotice: slowNotice)
        let coordinator = makeCoordinator([fast, slow])
        let updates = collect(coordinator)

        coordinator.submit("document")
        await coordinator.waitForPendingSearch()

        #expect(updates().first?.status == .searchingFiles)
        #expect(updates().last?.status == .message(slowNotice ?? "索引加载失败"))
    }

    @Test func emptyQuerySkipsSlowProviders() async {
        let fast = MockProvider(id: "fast", searchHandler: { _ in [makeItem(group: .app, canonicalKey: "app")] })
        let slow = MockProvider(id: "slow", phase: .slow, searchHandler: { _ in [makeItem(canonicalKey: "slow")] })
        let coordinator = makeCoordinator([fast, slow])
        let updates = collect(coordinator)

        coordinator.submit("")
        await coordinator.waitForPendingSearch()

        #expect(slow.receivedQueries.isEmpty)
        #expect(updates().last?.items.count == 1)
    }
}
