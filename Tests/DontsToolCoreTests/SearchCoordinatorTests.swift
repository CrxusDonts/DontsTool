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
        let knowledge = (0..<10).map { makeItem(group: .knowledge, title: "Document\($0)", score: Double(10 - $0), canonicalKey: "knowledge\($0)") }
        let files = [makeItem(group: .file, canonicalKey: "file")]
        let provider = MockProvider(id: "p", searchHandler: { _ in apps + tools + knowledge + files })
        let coordinator = makeCoordinator([provider])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        let items = updates().last!.items
        #expect(items.filter { $0.group == .app }.count == 8)
        #expect(items.filter { $0.group == .tool }.count == 8)
        #expect(items.first?.group == .app)
        #expect(items.filter { $0.group == .knowledge }.count == 8)
        #expect(items[16].group == .knowledge)
        #expect(items.last?.group == .file)
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
        let fast = MockProvider(id: "knowledge", keywords: ["kb"], statusNotice: "请先登录知识库")
        let coordinator = makeCoordinator([fast])
        let updates = collect(coordinator)

        coordinator.submit("kb document")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.status == .message("请先登录知识库"))
    }

    @Test(arguments: [nil, "文件搜索失败"] as [String?])
    func slowPhaseKeepsFastNoticeUnlessSlowProviderHasItsOwn(_ slowNotice: String?) async {
        let fast = MockProvider(id: "fast", statusNotice: "知识库连接失败")
        let slow = MockProvider(id: "file", phase: .slow, statusNotice: slowNotice)
        let coordinator = makeCoordinator([fast, slow])
        let updates = collect(coordinator)

        coordinator.submit("document")
        await coordinator.waitForPendingSearch()

        #expect(updates().first?.status == .searchingFiles)
        #expect(updates().last?.status == .message(slowNotice ?? "知识库连接失败"))
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
