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
            case .recent: "最近使用"
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

    public enum SearchEngine: String, CaseIterable, Identifiable, Codable, Sendable {
        case google
        case bing
        case baidu
        case ddg

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .google: "Google"
            case .bing: "必应"
            case .baidu: "百度"
            case .ddg: "DuckDuckGo"
            }
        }

        public func searchURL(for query: String) -> URL? {
            var components = URLComponents()
            components.scheme = "https"
            switch self {
            case .google:
                components.host = "www.google.com"
                components.path = "/search"
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            case .bing:
                components.host = "www.bing.com"
                components.path = "/search"
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            case .baidu:
                components.host = "www.baidu.com"
                components.path = "/s"
                components.queryItems = [URLQueryItem(name: "wd", value: query)]
            case .ddg:
                components.host = "duckduckgo.com"
                components.path = "/"
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            }
            return components.url
        }
    }

    private enum Key {
        static let hotKeyKind = "dontstool.hotkey.kind"
        static let hotKeyCode = "dontstool.hotkey.keyCode"
        static let hotKeyModifiers = "dontstool.hotkey.modifiers"
        static let defaultSearchEngine = "dontstool.defaultSearchEngine"
        static let applicationSortOrder = "dontstool.applicationSortOrder"
        static let enabledProviders = "dontstool.enabledProviders"
        static let fileSearchEnabled = "dontstool.fileSearchEnabled"
        static let translationTarget = "dontstool.translationTarget"
        static let translationAPIBaseURL = "dontstool.translationAPIBaseURL"
        static let translationAPIModel = "dontstool.translationAPIModel"
        static let selectionHoldDelay = "dontstool.selectionHoldDelay"
        static let selectionTranslationEnabled = "dontstool.selectionTranslationEnabled"
        static let knowledgeProviderMigrationCompleted = "dontstool.knowledgeProviderMigrationCompleted"
        static let builtInProviderDefaultsV2Completed = "dontstool.builtInProviderDefaultsV2Completed"
        static let applicationWorkflowsMigrationCompleted = "dontstool.applicationWorkflowsMigrationCompleted"
        static let knowledgeBaseURL = "dontstool.knowledgeBaseURL"
        static let hasCompletedOnboarding = "dontstool.hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    @Published public private(set) var hotKey: HotKeyConfiguration
    @Published public private(set) var defaultSearchEngine: SearchEngine
    @Published public private(set) var applicationSortOrder: ApplicationSortOrder
    @Published public private(set) var enabledProviderIDs: Set<String>
    @Published public private(set) var fileSearchEnabled: Bool
    @Published public private(set) var translationTarget: String
    @Published public private(set) var translationAPIBaseURL: String
    @Published public private(set) var translationAPIModel: String
    @Published public private(set) var selectionHoldDelay: SelectionHoldDelay
    @Published public private(set) var selectionTranslationEnabled: Bool
    @Published public private(set) var knowledgeBaseURL: String
    @Published public private(set) var hasCompletedOnboarding: Bool

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

        defaultSearchEngine = SearchEngine(
            rawValue: defaults.string(forKey: Key.defaultSearchEngine) ?? ""
        ) ?? .google
        applicationSortOrder = ApplicationSortOrder(
            rawValue: defaults.string(forKey: Key.applicationSortOrder) ?? ""
        ) ?? .recent

        let storedProviders = defaults.array(forKey: Key.enabledProviders) as? [String]
        var enabledProviders = storedProviders.map(Set.init) ?? Set(ProviderID.allCases.map(\.rawValue))
        if !defaults.bool(forKey: Key.knowledgeProviderMigrationCompleted) {
            enabledProviders.insert(ProviderID.knowledge.rawValue)
            if storedProviders != nil {
                defaults.set(Array(enabledProviders).sorted(), forKey: Key.enabledProviders)
            }
            defaults.set(true, forKey: Key.knowledgeProviderMigrationCompleted)
        }
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
        selectionHoldDelay = SelectionHoldDelay(rawValue: defaults.integer(forKey: Key.selectionHoldDelay)) ?? .seconds2
        selectionTranslationEnabled = defaults.bool(forKey: Key.selectionTranslationEnabled)
        knowledgeBaseURL = defaults.string(forKey: Key.knowledgeBaseURL) ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    public func setHotKey(_ configuration: HotKeyConfiguration) {
        hotKey = configuration
        defaults.set(configuration.kind.rawValue, forKey: Key.hotKeyKind)
        defaults.set(Int(configuration.keyCode), forKey: Key.hotKeyCode)
        defaults.set(Int(configuration.modifiers), forKey: Key.hotKeyModifiers)
    }

    public func setDefaultSearchEngine(_ engine: SearchEngine) {
        defaultSearchEngine = engine
        defaults.set(engine.rawValue, forKey: Key.defaultSearchEngine)
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

    public func setSelectionHoldDelay(_ delay: SelectionHoldDelay) {
        selectionHoldDelay = delay
        defaults.set(delay.rawValue, forKey: Key.selectionHoldDelay)
    }

    public func setSelectionTranslationEnabled(_ enabled: Bool) {
        selectionTranslationEnabled = enabled
        defaults.set(enabled, forKey: Key.selectionTranslationEnabled)
    }

    public func setKnowledgeBaseURL(_ url: String) {
        knowledgeBaseURL = url
        defaults.set(url, forKey: Key.knowledgeBaseURL)
    }

    public func completeOnboarding() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Key.hasCompletedOnboarding)
    }

    public func resetOnboarding() {
        hasCompletedOnboarding = false
        defaults.set(false, forKey: Key.hasCompletedOnboarding)
    }
}
