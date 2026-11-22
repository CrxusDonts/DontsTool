import Combine
import Foundation

@MainActor
public final class SettingsStore: ObservableObject {
    public static let legacyMigratedProfileID = "legacy-default"

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
        static let aiModelProfiles = "dontstool.aiModelProfiles"
        static let aiDefaultModelProfileID = "dontstool.aiDefaultModelProfileID"
        static let aiTranslationModelProfileID = "dontstool.aiTranslationModelProfileID"
        static let aiQuickAIModelProfileID = "dontstool.aiQuickAIModelProfileID"
        static let aiConsumerModelBindings = "dontstool.aiConsumerModelBindings"
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
        public var aiModelProfiles: [AIModelProfile]?
        public var defaultAIModelProfileID: String?
        public var translationAIModelProfileID: String?
        public var quickAIAIModelProfileID: String?
        public var aiConsumerModelBindings: [String: String]?

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
            aiAPIFormat: String? = nil,
            aiModelProfiles: [AIModelProfile]? = nil,
            defaultAIModelProfileID: String? = nil,
            translationAIModelProfileID: String? = nil,
            quickAIAIModelProfileID: String? = nil,
            aiConsumerModelBindings: [String: String]? = nil
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
            self.aiModelProfiles = aiModelProfiles
            self.defaultAIModelProfileID = defaultAIModelProfileID
            self.translationAIModelProfileID = translationAIModelProfileID
            self.quickAIAIModelProfileID = quickAIAIModelProfileID
            self.aiConsumerModelBindings = aiConsumerModelBindings
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
    @Published public private(set) var aiModelProfiles: [AIModelProfile]
    @Published public private(set) var defaultAIModelProfileID: String?
    @Published public private(set) var aiConsumerModelBindings: [String: String]

    public var translationAIModelProfileID: String? {
        aiConsumerModelBindings[AIConsumerID.translation]
    }

    public var quickAIAIModelProfileID: String? {
        aiConsumerModelBindings[AIConsumerID.legacyQuickAIPlugin]
    }
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
        let loadedBaseURL = defaults.string(forKey: Key.translationAPIBaseURL) ?? ""
        let loadedModel = defaults.string(forKey: Key.translationAPIModel) ?? ""
        let loadedFormat = AIAPIFormat(rawValue: defaults.string(forKey: Key.aiAPIFormat) ?? "") ?? .openAIResponses
        translationAPIBaseURL = loadedBaseURL
        translationAPIModel = loadedModel
        aiAPIFormat = loadedFormat

        var initialProfiles: [AIModelProfile] = []
        var initialDefaultID: String?
        var rawInitialBindings: [String: String] = [:]
        var didMigrateLegacyProfile = false
        var didMigrateLegacyBindings = false

        if let storedProfilesData = defaults.data(forKey: Key.aiModelProfiles) {
            if let decoded = try? JSONDecoder().decode([AIModelProfile].self, from: storedProfilesData) {
                initialProfiles = Self.normalizedProfiles(decoded)
            }
            initialDefaultID = defaults.string(forKey: Key.aiDefaultModelProfileID)
            if let bindingsData = defaults.data(forKey: Key.aiConsumerModelBindings),
               let decodedBindings = try? JSONDecoder().decode([String: String].self, from: bindingsData) {
                rawInitialBindings = decodedBindings
            } else {
                if let legacyTranslationID = defaults.string(forKey: Key.aiTranslationModelProfileID) {
                    rawInitialBindings[AIConsumerID.translation] = legacyTranslationID
                    didMigrateLegacyBindings = true
                }
                if let legacyQuickAIID = defaults.string(forKey: Key.aiQuickAIModelProfileID) {
                    rawInitialBindings[AIConsumerID.legacyQuickAIPlugin] = legacyQuickAIID
                    didMigrateLegacyBindings = true
                }
            }
        } else {
            let trimmedBase = loadedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedModel = loadedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedBase.isEmpty || !trimmedModel.isEmpty {
                let inferredName = !trimmedModel.isEmpty ? trimmedModel : loadedFormat.displayName
                initialProfiles = [
                    AIModelProfile(
                        id: Self.legacyMigratedProfileID,
                        name: inferredName,
                        format: loadedFormat,
                        baseURL: trimmedBase,
                        model: trimmedModel
                    )
                ]
                initialDefaultID = Self.legacyMigratedProfileID
                didMigrateLegacyProfile = true
            }
        }

        let validProfileIDs = Set(initialProfiles.map(\.id))
        if let candidate = initialDefaultID, validProfileIDs.contains(candidate) {
            defaultAIModelProfileID = candidate
        } else {
            defaultAIModelProfileID = initialProfiles.first?.id
        }
        aiConsumerModelBindings = Self.normalizedBindings(rawInitialBindings, validProfileIDs: validProfileIDs)
        aiModelProfiles = initialProfiles

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

        if didMigrateLegacyProfile || didMigrateLegacyBindings {
            persistAIModelProfiles()
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

    // MARK: - Multi-Profile AI Model Services

    public func aiModelProfile(id: String) -> AIModelProfile? {
        aiModelProfiles.first { $0.id == id }
    }

    public func aiModelProfileID(forConsumerID consumerID: String) -> String? {
        let trimmed = consumerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let boundID = aiConsumerModelBindings[trimmed] else {
            return nil
        }
        return aiModelProfiles.contains(where: { $0.id == boundID }) ? boundID : nil
    }

    public func resolvedAIModelProfile(forConsumerID consumerID: String?) -> AIModelProfile? {
        if let consumerID {
            let trimmed = consumerID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               let boundID = aiConsumerModelBindings[trimmed],
               let matched = aiModelProfile(id: boundID) {
                return matched
            }
        }
        if let defaultID = defaultAIModelProfileID, let matched = aiModelProfile(id: defaultID) {
            return matched
        }
        return aiModelProfiles.first
    }

    public func resolvedAIModelProfile(for purpose: AIUsagePurpose) -> AIModelProfile? {
        resolvedAIModelProfile(forConsumerID: purpose.consumerID)
    }

    public func resolvedAIConfiguration(forConsumerID consumerID: String?) -> ResolvedAIConfiguration {
        if let profile = resolvedAIModelProfile(forConsumerID: consumerID) {
            return ResolvedAIConfiguration(
                profileID: profile.id,
                profileName: profile.name,
                format: profile.format,
                baseURL: profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: profile.model.trimmingCharacters(in: .whitespacesAndNewlines),
                secretAccount: profile.secretAccount
            )
        }
        return ResolvedAIConfiguration(
            profileID: nil,
            profileName: nil,
            format: aiAPIFormat,
            baseURL: translationAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: translationAPIModel.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccount: SecretAccount.translationAPIKey
        )
    }

    public func resolvedAIConfiguration(for purpose: AIUsagePurpose) -> ResolvedAIConfiguration {
        resolvedAIConfiguration(forConsumerID: purpose.consumerID)
    }

    public func apiKey(for config: ResolvedAIConfiguration, secrets: SecretStoring) -> String? {
        if let direct = secrets.secret(for: config.secretAccount), !direct.isEmpty {
            return direct
        }
        if config.profileID == nil || config.profileID == Self.legacyMigratedProfileID {
            if let legacy = secrets.secret(for: SecretAccount.translationAPIKey), !legacy.isEmpty {
                return legacy
            }
        }
        return nil
    }

    public func apiKey(for profile: AIModelProfile, secrets: SecretStoring) -> String? {
        if let direct = secrets.secret(for: profile.secretAccount), !direct.isEmpty {
            return direct
        }
        if profile.id == Self.legacyMigratedProfileID {
            if let legacy = secrets.secret(for: SecretAccount.translationAPIKey), !legacy.isEmpty {
                return legacy
            }
        }
        return nil
    }

    public func saveAPIKey(_ key: String?, for profile: AIModelProfile, secrets: SecretStoring) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        secrets.setSecret(normalized, for: profile.secretAccount)
        if profile.id == Self.legacyMigratedProfileID {
            secrets.setSecret(normalized, for: SecretAccount.translationAPIKey)
        }
    }

    public func upsertAIModelProfile(_ profile: AIModelProfile, makeDefault: Bool = false) {
        let normalized = Self.normalizeProfile(profile)
        var updated = aiModelProfiles
        if let index = updated.firstIndex(where: { $0.id == normalized.id }) {
            updated[index] = normalized
        } else {
            updated.append(normalized)
        }
        aiModelProfiles = updated
        if makeDefault
            || defaultAIModelProfileID == nil
            || !updated.contains(where: { $0.id == defaultAIModelProfileID }) {
            defaultAIModelProfileID = normalized.id
        }
        persistAIModelProfiles()
        syncLegacyFieldsFromActiveTranslationProfile()
    }

    public func deleteAIModelProfile(id: String, secrets: SecretStoring? = nil) {
        var updated = aiModelProfiles
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            return
        }
        let removed = updated.remove(at: index)
        aiModelProfiles = updated

        if let secrets {
            secrets.setSecret(nil, for: removed.secretAccount)
            if removed.id == Self.legacyMigratedProfileID {
                secrets.setSecret(nil, for: SecretAccount.translationAPIKey)
            }
        }

        if defaultAIModelProfileID == id
            || defaultAIModelProfileID == nil
            || !updated.contains(where: { $0.id == defaultAIModelProfileID }) {
            defaultAIModelProfileID = updated.first?.id
        }
        aiConsumerModelBindings = aiConsumerModelBindings.filter { $0.value != id }
        persistAIModelProfiles()
        syncLegacyFieldsFromActiveTranslationProfile()
    }

    public func setDefaultAIModelProfileID(_ id: String?) {
        if let id, aiModelProfiles.contains(where: { $0.id == id }) {
            defaultAIModelProfileID = id
        } else {
            defaultAIModelProfileID = aiModelProfiles.first?.id
        }
        persistAIModelProfiles()
        syncLegacyFieldsFromActiveTranslationProfile()
    }

    public func setAIModelProfileID(_ id: String?, forConsumerID consumerID: String) {
        let trimmedConsumer = consumerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConsumer.isEmpty else { return }
        var updated = aiConsumerModelBindings
        if let id, aiModelProfiles.contains(where: { $0.id == id }) {
            updated[trimmedConsumer] = id
        } else {
            updated.removeValue(forKey: trimmedConsumer)
        }
        aiConsumerModelBindings = updated
        persistAIModelProfiles()
        if trimmedConsumer == AIConsumerID.translation {
            syncLegacyFieldsFromActiveTranslationProfile()
        }
    }

    public func setTranslationAIModelProfileID(_ id: String?) {
        setAIModelProfileID(id, forConsumerID: AIConsumerID.translation)
    }

    public func setQuickAIAIModelProfileID(_ id: String?) {
        setAIModelProfileID(id, forConsumerID: AIConsumerID.legacyQuickAIPlugin)
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
            aiAPIFormat: aiAPIFormat.rawValue,
            aiModelProfiles: aiModelProfiles,
            defaultAIModelProfileID: defaultAIModelProfileID,
            translationAIModelProfileID: translationAIModelProfileID,
            quickAIAIModelProfileID: quickAIAIModelProfileID,
            aiConsumerModelBindings: aiConsumerModelBindings
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

        if let syncedProfiles = synced.aiModelProfiles {
            let normalized = Self.normalizedProfiles(syncedProfiles)
            let validIDs = Set(normalized.map(\.id))
            aiModelProfiles = normalized
            if let candidate = synced.defaultAIModelProfileID, validIDs.contains(candidate) {
                defaultAIModelProfileID = candidate
            } else {
                defaultAIModelProfileID = normalized.first?.id
            }
            if let syncedBindings = synced.aiConsumerModelBindings {
                aiConsumerModelBindings = Self.normalizedBindings(syncedBindings, validProfileIDs: validIDs)
            } else {
                var migrated: [String: String] = [:]
                if let id = synced.translationAIModelProfileID {
                    migrated[AIConsumerID.translation] = id
                }
                if let id = synced.quickAIAIModelProfileID {
                    migrated[AIConsumerID.legacyQuickAIPlugin] = id
                }
                aiConsumerModelBindings = Self.normalizedBindings(migrated, validProfileIDs: validIDs)
            }
            persistAIModelProfiles()
            if !normalized.isEmpty {
                syncLegacyFieldsFromActiveTranslationProfile()
            }
        } else if aiModelProfiles.count == 1, aiModelProfiles[0].id == Self.legacyMigratedProfileID {
            let trimmedBase = translationAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedModel = translationAPIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedBase.isEmpty || !trimmedModel.isEmpty {
                let existingName = aiModelProfiles[0].name
                let resolvedName = existingName.isEmpty
                    ? (!trimmedModel.isEmpty ? trimmedModel : aiAPIFormat.displayName)
                    : existingName
                aiModelProfiles = [
                    AIModelProfile(
                        id: Self.legacyMigratedProfileID,
                        name: resolvedName,
                        format: aiAPIFormat,
                        baseURL: trimmedBase,
                        model: trimmedModel
                    )
                ]
                defaultAIModelProfileID = Self.legacyMigratedProfileID
            } else {
                aiModelProfiles = []
                defaultAIModelProfileID = nil
                aiConsumerModelBindings = [:]
            }
            persistAIModelProfiles()
        }
    }

    // MARK: - Private AI Profile Helpers

    private func persistAIModelProfiles() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let encoded = try? encoder.encode(aiModelProfiles) {
            defaults.set(encoded, forKey: Key.aiModelProfiles)
        }
        if let encodedBindings = try? encoder.encode(aiConsumerModelBindings) {
            defaults.set(encodedBindings, forKey: Key.aiConsumerModelBindings)
        }
        setOptionalString(defaultAIModelProfileID, forKey: Key.aiDefaultModelProfileID)
        setOptionalString(translationAIModelProfileID, forKey: Key.aiTranslationModelProfileID)
        setOptionalString(quickAIAIModelProfileID, forKey: Key.aiQuickAIModelProfileID)
    }

    private func setOptionalString(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func syncLegacyFieldsFromActiveTranslationProfile() {
        if let active = resolvedAIModelProfile(for: .translation) {
            let trimmedBase = active.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedModel = active.model.trimmingCharacters(in: .whitespacesAndNewlines)
            setTranslationAPIBaseURL(trimmedBase)
            setTranslationAPIModel(trimmedModel)
            setAIAPIFormat(active.format)
        } else {
            setTranslationAPIBaseURL("")
            setTranslationAPIModel("")
        }
    }

    private static func normalizedBindings(
        _ raw: [String: String],
        validProfileIDs: Set<String>
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (rawKey, rawValue) in raw {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, validProfileIDs.contains(value) else {
                continue
            }
            result[key] = value
        }
        return result
    }

    private static func normalizeProfile(_ profile: AIModelProfile) -> AIModelProfile {
        let trimmedID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = trimmedID.isEmpty ? UUID().uuidString : trimmedID
        let trimmedBaseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if !trimmedName.isEmpty {
            resolvedName = trimmedName
        } else if !trimmedModel.isEmpty {
            resolvedName = trimmedModel
        } else {
            resolvedName = profile.format.displayName
        }
        return AIModelProfile(
            id: resolvedID,
            name: resolvedName,
            format: profile.format,
            baseURL: trimmedBaseURL,
            model: trimmedModel
        )
    }

    private static func normalizedProfiles(_ raw: [AIModelProfile]) -> [AIModelProfile] {
        var seen: Set<String> = []
        var result: [AIModelProfile] = []
        for profile in raw {
            let normalized = normalizeProfile(profile)
            if seen.insert(normalized.id).inserted {
                result.append(normalized)
            }
        }
        return result
    }
}
