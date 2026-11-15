import Foundation
import Testing
@testable import DontsToolCore

@Suite("Launcher attached content")
@MainActor
struct LauncherContentModelTests {
    @Test func attachedContentFiltersActionsWithoutSubmittingSourceToSearch() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let tools = MockToolOpener()
        var searched: [String] = []
        let provider = MockProvider(id: "global", searchHandler: { context in
            searched.append(context.rawQuery)
            return []
        })
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [provider]), slowDelay: .zero)
        let content = ContentActionProvider(settings: SettingsStore(defaults: defaults), toolOpener: tools,
            urlOpener: MockURLOpener(), feedback: MockFeedback())
        let model = LauncherPanelModel(coordinator: coordinator, hotKeyDisplay: "⌥⌥", contentProvider: content)
        let original = "  hello\nworld  "
        #expect(model.attachContent(original))
        #expect(model.attachedContent?.kind == .text)
        model.submit("b64d")
        await coordinator.waitForPendingSearch()
        #expect(searched.isEmpty)
        #expect(model.items.map(\.keyword) == ["b64d"])
        try await model.selectedItem?.primaryAction?.run()
        #expect(tools.requests.first?.input == original)
        #expect(model.clearContent())
        #expect(model.items.isEmpty)
        #expect(model.selectedItem == nil)
        #expect(model.actionItems.isEmpty)
        await coordinator.waitForPendingSearch()
        #expect(model.attachedContent == nil)
        #expect(searched == [""])
    }

    @Test func attachingContentCancelsOldResultsAndResetsActionSelection() async {
        let provider = MockProvider(id: "global", searchHandler: { _ in
            [SearchItem(providerID: "global", group: .app, title: "Old", icon: .symbol(name: "app", tint: .blue),
                score: 1, canonicalKey: "old", actions: [ItemAction(id: "open", title: "打开") {}])]
        })
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [provider]), slowDelay: .zero)
        let content = ContentActionProvider(settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            toolOpener: MockToolOpener(), urlOpener: MockURLOpener(), feedback: MockFeedback())
        let model = LauncherPanelModel(coordinator: coordinator, hotKeyDisplay: "⌥⌥", contentProvider: content)
        model.submit("old")
        await coordinator.waitForPendingSearch()
        model.openActionPanel()
        #expect(model.isActionPanelOpen)
        model.submit("queued")
        #expect(model.attachContent("{\"answer\":42}"))
        await coordinator.waitForPendingSearch()
        #expect(model.items.map(\.keyword) == ["json"])
        #expect(!model.isActionPanelOpen)
        #expect(model.selectedIndex == 0)
        #expect(!model.isDefaultList)
    }
}
