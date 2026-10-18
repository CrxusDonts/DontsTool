import Foundation
import ServiceManagement

/// 登录项开关：SMAppService 管理主应用登录项。
@MainActor
public final class LoginItemManager: ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var message: String?

    public init() {
        refresh()
    }

    public func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }
}
