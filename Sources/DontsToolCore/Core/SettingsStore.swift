import Combine
import Foundation

@MainActor
public final class SettingsStore: ObservableObject {
    public enum ApplicationSortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
        case recent
        case frequency
        case name

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .recent: "最近打开"
            case .frequency: "使用频率"
            case .name: "名称"
            }
        }
    }

    public struct HotKeyConfiguration: Equatable, Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case combination
            case doubleTap
        }

        /// Carbon 的修饰键位与 NSEvent.ModifierFlags 不同，录制时必须显式转换。
        public enum Modifier: UInt32, CaseIterable, Sendable {
            case command = 256
            case shift = 512
            case option = 2048
            case control = 4096
        }

        public var kind: Kind
        public var keyCode: UInt32
        public var modifiers: UInt32

        public init(kind: Kind = .combination, keyCode: UInt32, modifiers: UInt32) {
            self.kind = kind
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        public var doubleTapModifier: Modifier? {
            guard kind == .doubleTap else { return nil }
            return Modifier(rawValue: modifiers)
        }

        public static func doubleTap(_ modifier: Modifier) -> HotKeyConfiguration {
            HotKeyConfiguration(kind: .doubleTap, keyCode: 0, modifiers: modifier.rawValue)
        }

        public static func carbonModifiers(
            command: Bool,
            shift: Bool,
            option: Bool,
            control: Bool
        ) -> UInt32 {
            var modifiers: UInt32 = 0
            if command { modifiers |= Modifier.command.rawValue }
            if shift { modifiers |= Modifier.shift.rawValue }
            if option { modifiers |= Modifier.option.rawValue }
            if control { modifiers |= Modifier.control.rawValue }
            return modifiers
        }

        public static let optionSpace = HotKeyConfiguration(
            keyCode: 49,
            modifiers: Modifier.option.rawValue
        )
    }

    private enum Key {
        static let hotKeyKind = "dontstool.hotkey.kind"
        static let hotKeyCode = "dontstool.hotkey.keyCode"
        static let hotKeyModifiers = "dontstool.hotkey.modifiers"
        static let applicationSortOrder = "dontstool.applicationSortOrder"
        static let enabledProviders = "dontstool.enabledProviders"
        static let fileSearchEnabled = "dontstool.fileSearchEnabled"
        static let translationTarget = "dontstool.translationTarget"
        static let translationAPIBaseURL = "dontstool.translationAPIBaseURL"
        static let translationAPIModel = "dontstool.translationAPIModel"
        static let aiAPIFormat = "dontstool.aiAPIFormat"
        static let selectionHoldDelay = "dontstool.selectionHoldDelay"
        static let selectionTranslationEnabled = "dontstool.selectionTranslationEnabled"
        static let builtInProviderDefaultsV2Completed = "dontstool.builtInProviderDefaultsV2Completed"
        static let applicationWorkflowsMigrationCompleted = "dontstool.applicationWorkflowsMigrationCompleted"
        static let notesProviderMigrationCompleted = "dontstool.notesProviderMigrationCompleted"
        static let killProcessProviderMigrationCompleted = "dontstool.killProcessProviderMigrationCompleted"
        static let chromeProviderMigrationCompleted = "dontstool.chromeProviderMigrationCompleted"
        static let terminalFinderProviderMigrationCompleted = "dontstool.terminalFinderProviderMigrationCompleted"
        static let preferredTerminalBundleID = "dontstool.preferredTerminalBundleID"
        static let hasCompletedOnboarding = "dontstool.hasCompletedOnboarding"
        static let cloudSyncEnabled = "dontstool.cloudSync.enabled"
        static let cloudSyncServerURL = "dontstool.cloudSync.serverURL"
        static let cloudSyncDeviceID = "dontstool.cloudSync.deviceID"
    }

    public struct SyncedAppSettings: Codable, Equatable, Sendable {
        public var hotKey: HotKeyConfiguration
        public var applicationSortOrder: ApplicationSortOrder
        public var enabledProviderIDs: [String]
        public var fileSearchEnabled: Bool
        public var translationTarget: String
        public var translationAPIBaseURL: String
        public var translationAPIModel: String
        public var selectionHoldDelayRawValue: Int
        public var selectionTranslationEnabled: Bool
        public var preferredTerminalBundleID: String?
        public var aiAPIFormat: String?

        public init(
            hotKey: HotKeyConfiguration,
            applicationSortOrder: ApplicationSortOrder,
            enabledProviderIDs: [String],
            fileSearchEnabled: Bool,
            translationTarget: String,
            translationAPIBaseURL: String,
            translationAPIModel: String,
            selectionHoldDelayRawValue: Int,
            selectionTranslationEnabled: Bool,
            preferredTerminalBundleID: String? = nil,
            aiAPIFormat: String? = nil
        ) {
            self.hotKey = hotKey
            self.applicationSortOrder = applicationSortOrder
            self.enabledProviderIDs = enabledProviderIDs.sorted()
            self.fileSearchEnabled = fileSearchEnabled
            self.translationTarget = translationTarget
            self.translationAPIBaseURL = translationAPIBaseURL
            self.translationAPIModel = translationAPIModel
            self.selectionHoldDelayRawValue = selectionHoldDelayRawValue
            self.selectionTranslationEnabled = selectionTranslationEnabled
            self.preferredTerminalBundleID = preferredTerminalBundleID
            self.aiAPIFormat = aiAPIFormat
        }
    }

    private let defaults: UserDefaults

    @Published public private(set) var hotKey: HotKeyConfiguration
    @Published public private(set) var applicationSortOrder: ApplicationSortOrder
    @Published public private(set) var enabledProviderIDs: Set<String>
    @Published public private(set) var fileSearchEnabled: Bool
    @Published public private(set) var translationTarget: String
    @Published public private(set) var translationAPIBaseURL: String
    @Published public private(set) var translationAPIModel: String
    @Published public private(set) var aiAPIFormat: AIAPIFormat
    @Published public private(set) var selectionHoldDelay: SelectionHoldDelay
    @Published public private(set) var selectionTranslationEnabled: Bool
    @Published public private(set) var preferredTerminalBundleID: String
    @Published public private(set) var hasCompletedOnboarding: Bool
    @Published public private(set) var cloudSyncEnabled: Bool
    @Published public private(set) var cloudSyncServerURL: String
    public let cloudSyncDeviceID: String

    public var hotKeyChanges: AnyPublisher<HotKeyConfiguration, Never> {
        $hotKey.eraseToAnyPublisher()
    }

    public init(defaults: UserDefaults = .standard, systemLanguageCode: String? = nil) {
        self.defaults = defaults

        if defaults.object(forKey: Key.hotKeyCode) != nil {
            let kind = HotKeyConfiguration.Kind(
                rawValue: defaults.string(forKey: Key.hotKeyKind) ?? ""
            ) ?? .combination
            hotKey = HotKeyConfiguration(
                kind: kind,
                keyCode: UInt32(defaults.integer(forKey: Key.hotKeyCode)),
                modifiers: UInt32(defaults.integer(forKey: Key.hotKeyModifiers))
            )
        } else {
            hotKey = .optionSpace
        }

        applicationSortOrder = ApplicationSortOrder(
            rawValue: defaults.string(forKey: Key.applicationSortOrder) ?? ""
        ) ?? .recent

        let storedProviders = defaults.array(forKey: Key.enabledProviders) as? [String]
        var enabledProviders = storedProviders.map(Set.init) ?? Set(ProviderID.allCases.map(\.rawValue))
        if !defaults.bool(forKey: Key.builtInProviderDefaultsV2Completed) {
            enabledProviders.formUnion([
                ProviderID.calculator.rawValue,
                ProviderID.quickOpen.rawValue
            ])
            if storedProviders != nil {
                defaults.set(Array(enabledProviders).sorted(), forKey: Key.enabledProviders)
            }
            defaults.set(true, forKey: Key.builtInProviderDefaultsV2Completed)
        }
        if !defaults.bool(forKey: Key.applicationWorkflowsMigrationCompleted) {
            enabledProviders.formUnion([ProviderID.gemini.rawValue, ProviderID.ideaProjects.rawValue])
            if storedProviders != nil {
                defaults.set(Array(enabledProviders).sorted(), forKey: Key.enabledProviders)
            }
            defaults.set(true, forKey: Key.applicationWorkflowsMigrationCompleted)
        }
        if !defaults.bool(forKey: Key.notesProviderMigrationCompleted) {
            enabledProviders.insert(ProviderID.notes.rawValue)
            if storedProviders != nil {
                defaults.set(Array(enabledProviders).sorted(), forKey: Key.enabledProviders)
            }
            defaults.set(true, forKey: Key.notesProviderMigrationCompleted)
        }
        if !defaults.bool(forKey: Key.killProcessProviderMigrationCompleted) {
            enabledProviders.insert(ProviderID.killProcess.rawValue)
            if storedProviders != nil {
                defaults.set(Array(enabledProviders).sorted(), forKey: Key.enabledProviders)
            }
            defaults.set(true, forKey: Key.killProcessProviderMigrationCompleted)
        }
        if !defaults.bool(forKey: Key.chromeProviderMigrationCompleted) {
            enabledProviders.insert(ProviderID.chrome.rawValue)
            if storedProviders != nil {
                defaults.set(Array(enabledProviders).sorted(), forKey: Key.enabledProviders)
            }
            defaults.set(true, forKey: Key.chromeProviderMigrationCompleted)
        }
        if !defaults.bool(forKey: Key.terminalFinderProviderMigrationCompleted) {
            enabledProviders.insert(ProviderID.terminalFinder.rawValue)
            if storedProviders != nil {
                defaults.set(Array(enabledProviders).sorted(), forKey: Key.enabledProviders)
            }
            defaults.set(true, forKey: Key.terminalFinderProviderMigrationCompleted)
        }
        enabledProviders.remove("knowledge")
        enabledProviderIDs = enabledProviders

        if defaults.object(forKey: Key.fileSearchEnabled) != nil {
            fileSearchEnabled = defaults.bool(forKey: Key.fileSearchEnabled)
        } else {
            fileSearchEnabled = true
        }

        let languageCode = systemLanguageCode ?? Locale.current.language.languageCode?.identifier
        let fallbackTarget = languageCode == "zh" ? "zh-Hans" : "en"
        translationTarget = defaults.string(forKey: Key.translationTarget) ?? fallbackTarget
        translationAPIBaseURL = defaults.string(forKey: Key.translationAPIBaseURL) ?? ""
        translationAPIModel = defaults.string(forKey: Key.translationAPIModel) ?? ""
        aiAPIFormat = AIAPIFormat(rawValue: defaults.string(forKey: Key.aiAPIFormat) ?? "") ?? .openAIResponses
        selectionHoldDelay = SelectionHoldDelay(rawValue: defaults.integer(forKey: Key.selectionHoldDelay)) ?? .seconds2
        selectionTranslationEnabled = defaults.bool(forKey: Key.selectionTranslationEnabled)
        preferredTerminalBundleID = defaults.string(forKey: Key.preferredTerminalBundleID) ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        cloudSyncEnabled = defaults.bool(forKey: Key.cloudSyncEnabled)
        cloudSyncServerURL = defaults.string(forKey: Key.cloudSyncServerURL) ?? ""
        if let existingDeviceID = defaults.string(forKey: Key.cloudSyncDeviceID),
           !existingDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cloudSyncDeviceID = existingDeviceID
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Key.cloudSyncDeviceID)
            cloudSyncDeviceID = generated
        }
    }

    public func setHotKey(_ configuration: HotKeyConfiguration) {
        hotKey = configuration
        defaults.set(configuration.kind.rawValue, forKey: Key.hotKeyKind)
        defaults.set(Int(configuration.keyCode), forKey: Key.hotKeyCode)
        defaults.set(Int(configuration.modifiers), forKey: Key.hotKeyModifiers)
    }

    public func setApplicationSortOrder(_ order: ApplicationSortOrder) {
        applicationSortOrder = order
        defaults.set(order.rawValue, forKey: Key.applicationSortOrder)
    }

    public func isProviderEnabled(_ id: String) -> Bool {
        enabledProviderIDs.contains(id)
    }

    public func setProviderEnabled(_ id: String, to isEnabled: Bool) {
        if isEnabled {
            enabledProviderIDs.insert(id)
        } else {
            enabledProviderIDs.remove(id)
        }
        defaults.set(Array(enabledProviderIDs).sorted(), forKey: Key.enabledProviders)
    }

    public func setFileSearchEnabled(_ isEnabled: Bool) {
        fileSearchEnabled = isEnabled
        defaults.set(isEnabled, forKey: Key.fileSearchEnabled)
    }

    public func setTranslationTarget(_ identifier: String) {
        translationTarget = identifier
        defaults.set(identifier, forKey: Key.translationTarget)
    }

    public func setTranslationAPIBaseURL(_ url: String) {
        translationAPIBaseURL = url
        defaults.set(url, forKey: Key.translationAPIBaseURL)
    }

    public func setTranslationAPIModel(_ model: String) {
        translationAPIModel = model
        defaults.set(model, forKey: Key.translationAPIModel)
    }

    public func setAIAPIFormat(_ format: AIAPIFormat) {
        aiAPIFormat = format
        defaults.set(format.rawValue, forKey: Key.aiAPIFormat)
    }

    public func setSelectionHoldDelay(_ delay: SelectionHoldDelay) {
        selectionHoldDelay = delay
        defaults.set(delay.rawValue, forKey: Key.selectionHoldDelay)
    }

    public func setSelectionTranslationEnabled(_ enabled: Bool) {
        selectionTranslationEnabled = enabled
        defaults.set(enabled, forKey: Key.selectionTranslationEnabled)
    }

    public func setPreferredTerminalBundleID(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        preferredTerminalBundleID = trimmed
        defaults.set(trimmed, forKey: Key.preferredTerminalBundleID)
    }

    public func completeOnboarding() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Key.hasCompletedOnboarding)
    }

    public func resetOnboarding() {
        hasCompletedOnboarding = false
        defaults.set(false, forKey: Key.hasCompletedOnboarding)
    }

    public func setCloudSyncEnabled(_ enabled: Bool) {
        cloudSyncEnabled = enabled
        defaults.set(enabled, forKey: Key.cloudSyncEnabled)
    }

    public func setCloudSyncServerURL(_ url: String) {
        cloudSyncServerURL = url
        defaults.set(url, forKey: Key.cloudSyncServerURL)
    }

    public func exportSyncedSettings() -> SyncedAppSettings {
        SyncedAppSettings(
            hotKey: hotKey,
            applicationSortOrder: applicationSortOrder,
            enabledProviderIDs: Array(enabledProviderIDs).sorted(),
            fileSearchEnabled: fileSearchEnabled,
            translationTarget: translationTarget,
            translationAPIBaseURL: translationAPIBaseURL,
            translationAPIModel: translationAPIModel,
            selectionHoldDelayRawValue: selectionHoldDelay.rawValue,
            selectionTranslationEnabled: selectionTranslationEnabled,
            preferredTerminalBundleID: preferredTerminalBundleID,
            aiAPIFormat: aiAPIFormat.rawValue
        )
    }

    public func applySyncedSettings(_ synced: SyncedAppSettings) {
        setHotKey(synced.hotKey)
        setApplicationSortOrder(synced.applicationSortOrder)
        var providers = Set(synced.enabledProviderIDs)
        providers.remove("knowledge")
        enabledProviderIDs = providers
        defaults.set(Array(providers).sorted(), forKey: Key.enabledProviders)
        setFileSearchEnabled(synced.fileSearchEnabled)
        setTranslationTarget(synced.translationTarget)
        setTranslationAPIBaseURL(synced.translationAPIBaseURL)
        setTranslationAPIModel(synced.translationAPIModel)
        setSelectionHoldDelay(SelectionHoldDelay(rawValue: synced.selectionHoldDelayRawValue) ?? .seconds2)
        setSelectionTranslationEnabled(synced.selectionTranslationEnabled)
        if let terminal = synced.preferredTerminalBundleID {
            setPreferredTerminalBundleID(terminal)
        }
        if let rawFormat = synced.aiAPIFormat,
           let format = AIAPIFormat(rawValue: rawFormat) {
            setAIAPIFormat(format)
        }
    }
}
