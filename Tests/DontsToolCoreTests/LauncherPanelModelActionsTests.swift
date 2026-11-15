import Foundation
import Testing
@testable import DontsToolCore

@Suite("LauncherPanelModel actions")
@MainActor
struct LauncherPanelModelActionsTests {
    private func makeModel(actionCount: Int = 3) -> (LauncherPanelModel, SearchCoordinator) {
        let actions = (0..<actionCount).map { index in
            ItemAction(id: "action\(index)", title: "Action \(index)", symbol: "circle") {}
        }
        let item = SearchItem(
            providerID: "mock",
            group: .tool,
            title: "Result",
            icon: .symbol(name: "circle", tint: .gray),
            score: 1,
            canonicalKey: "result",
            actions: actions
        )
        let provider = MockProvider(id: "mock", searchHandler: { _ in [item] })
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [provider]), slowDelay: .zero)
        let model = LauncherPanelModel(coordinator: coordinator, hotKeyDisplay: "⌥ Space")
        return (model, coordinator)
    }

    @Test func togglesAndNavigatesAllActions() async {
        let (model, coordinator) = makeModel()
        model.submit("query")
        await coordinator.waitForPendingSearch()

        #expect(!model.isActionPanelOpen)
        model.toggleActionPanel()
        #expect(model.isActionPanelOpen)
        #expect(model.actionItems.map(\.id) == ["action0", "action1", "action2"])
        #expect(model.selectedActionIndex == 0)

        model.moveActionSelection(by: 1)
        #expect(model.selectedActionIndex == 1)
        model.moveActionSelection(by: 10)
        #expect(model.selectedActionIndex == 2)
        model.moveActionSelection(by: -10)
        #expect(model.selectedActionIndex == 0)

        model.toggleActionPanel()
        #expect(!model.isActionPanelOpen)
    }

    @Test func changingQueryClosesActionPanel() async {
        let (model, coordinator) = makeModel()
        model.submit("query")
        await coordinator.waitForPendingSearch()
        model.toggleActionPanel()
        #expect(model.isActionPanelOpen)

        model.submit("next")
        await coordinator.waitForPendingSearch()
        #expect(!model.isActionPanelOpen)
    }

    @Test func itemWithoutActionsCannotOpenActionPanel() async {
        let (model, coordinator) = makeModel(actionCount: 0)
        model.submit("query")
        await coordinator.waitForPendingSearch()

        model.toggleActionPanel()
        #expect(!model.isActionPanelOpen)
    }

    @Test func selectingActionDirectlyUpdatesIndex() async {
        let (model, coordinator) = makeModel()
        model.submit("query")
        await coordinator.waitForPendingSearch()
        model.toggleActionPanel()

        model.selectAction(index: 2)
        #expect(model.selectedAction?.id == "action2")
    }
}
