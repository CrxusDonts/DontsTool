import Combine
import Foundation

@MainActor
public final class PluginSettingsStore: ObservableObject {
    private enum Key {
        static let disabledPluginIDs = "dontstool.plugins.disabledIDs"
        static let preferences = "dontstool.plugins.preferences"
    }

    private let defaults: UserDefaults

    @Published public private(set) var disabledPluginIDs: Set<String>
    @Published public private(set) var preferencesByPlugin: [String: [String: String]]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let disabled = defaults.array(forKey: Key.disabledPluginIDs) as? [String] ?? []
        self.disabledPluginIDs = Set(disabled)
        self.preferencesByPlugin = defaults.dictionary(forKey: Key.preferences) as? [String: [String: String]] ?? [:]
    }

    public func isPluginEnabled(_ pluginID: String) -> Bool {
        !disabledPluginIDs.contains(pluginID)
    }

    public func setPluginEnabled(_ pluginID: String, to enabled: Bool) {
        if enabled {
            disabledPluginIDs.remove(pluginID)
        } else {
            disabledPluginIDs.insert(pluginID)
        }
        defaults.set(Array(disabledPluginIDs).sorted(), forKey: Key.disabledPluginIDs)
    }

    public func preferenceValue(pluginID: String, key: String) -> String? {
        preferencesByPlugin[pluginID]?[key]
    }

    public func setPreferenceValue(_ value: String?, pluginID: String, key: String) {
        var pluginMap = preferencesByPlugin[pluginID] ?? [:]
        if let value {
            pluginMap[key] = value
        } else {
            pluginMap.removeValue(forKey: key)
        }
        if pluginMap.isEmpty {
            preferencesByPlugin.removeValue(forKey: pluginID)
        } else {
            preferencesByPlugin[pluginID] = pluginMap
        }
        defaults.set(preferencesByPlugin, forKey: Key.preferences)
    }

    public static func secretAccount(pluginID: String, key: String) -> String? {
        let trimmedID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PluginManifestLoader.isValidPluginID(trimmedID),
              !trimmedKey.isEmpty,
              !trimmedKey.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" }) else {
            return nil
        }
        return "plugin.\(trimmedID).\(trimmedKey)"
    }

    public func secret(forPluginID pluginID: String, key: String, using store: any SecretStoring) -> String? {
        guard let account = Self.secretAccount(pluginID: pluginID, key: key) else { return nil }
        return store.secret(for: account)
    }

    public func setSecret(_ value: String?, forPluginID pluginID: String, key: String, using store: any SecretStoring) {
        guard let account = Self.secretAccount(pluginID: pluginID, key: key) else { return }
        store.setSecret(value, for: account)
    }
}
