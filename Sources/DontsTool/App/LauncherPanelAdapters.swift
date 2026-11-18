import DontsToolCore
import Foundation

@MainActor
final class PanelPrefiller: QueryPrefilling {
    weak var panel: LauncherPanelController?

    func prefill(_ query: String) {
        panel?.prefill(query)
    }
}

@MainActor
final class PanelSettingsOpener: SettingsOpening {
    weak var panel: LauncherPanelController?

    func openSettings() {
        panel?.onOpenSettings?()
    }
}

@MainActor
final class PanelProgressReporter: OperationProgressReporting {
    weak var panel: LauncherPanelController?

    func begin(_ message: String) {
        panel?.begin(message)
    }

    func end() {
        panel?.end()
    }
}
