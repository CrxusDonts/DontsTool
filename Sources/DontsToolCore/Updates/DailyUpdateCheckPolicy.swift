import Foundation

/// 管理每日首次打开启动器的更新检查节流，以及启动器底栏忽略的版本记录。
@MainActor
public final class DailyUpdateCheckPolicy {
    private enum Key {
        static let lastDailyCheckDay = "dontstool.updates.lastDailyCheckDay"
        static let dismissedVersion = "dontstool.updates.dismissedVersion"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastCheckedDay: String? {
        defaults.string(forKey: Key.lastDailyCheckDay)
    }

    public var dismissedVersion: String? {
        let value = defaults.string(forKey: Key.dismissedVersion)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    public func shouldTriggerDailyCheck(
        now: Date = Date(),
        calendar: Calendar = .current,
        automaticallyChecks: Bool,
        hasAvailableUpdate: Bool
    ) -> Bool {
        guard automaticallyChecks, !hasAvailableUpdate else { return false }
        return lastCheckedDay != Self.dayString(for: now, calendar: calendar)
    }

    public func recordCheckAttempt(now: Date = Date(), calendar: Calendar = .current) {
        defaults.set(Self.dayString(for: now, calendar: calendar), forKey: Key.lastDailyCheckDay)
    }

    public func isVersionDismissed(_ version: String) -> Bool {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return dismissedVersion == normalized
    }

    public func dismissVersion(_ version: String) {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        defaults.set(normalized, forKey: Key.dismissedVersion)
    }

    public func clearDismissedVersion() {
        defaults.removeObject(forKey: Key.dismissedVersion)
    }

    private static func dayString(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
