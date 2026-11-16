import Combine
import Foundation

@MainActor
public final class SearchEngineStore: ObservableObject {
    @Published public private(set) var configuration: SearchEngineConfiguration
    @Published public private(set) var loadError: String?
    private let defaults: UserDefaults
    private static let key = "dontstool.searchEngines"
    private var damagedJSON: String?

    public var editableJSON: String { damagedJSON ?? (try? configuration.json()) ?? "" }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = .builtIn
        let storedText = defaults.data(forKey: Self.key).map { String(decoding: $0, as: UTF8.self) }
            ?? defaults.string(forKey: Self.key)
        if let text = storedText {
            do { configuration = try SearchEngineConfiguration.decode(text) }
            catch {
                damagedJSON = text
                loadError = "搜索配置加载失败：\(error.localizedDescription)。原配置已保留，可在 JSON 配置中修复。"
            }
        } else if let legacy = defaults.string(forKey: "dontstool.defaultSearchEngine"),
                  ["google", "bing", "baidu", "ddg"].contains(legacy) {
            configuration.defaultEngineID = legacy
        }
    }

    public func save(_ proposed: SearchEngineConfiguration, reservedKeywords: Set<String> = SearchEngineConfiguration.reservedKeywords) throws {
        let validated = try proposed.validated(reservedKeywords: reservedKeywords)
        let data = Data(try validated.json().utf8)
        defaults.set(data, forKey: Self.key)
        damagedJSON = nil
        loadError = nil
        configuration = validated
    }

    public func importJSON(_ text: String, reservedKeywords: Set<String> = SearchEngineConfiguration.reservedKeywords) throws {
        try save(SearchEngineConfiguration.decode(text, reservedKeywords: reservedKeywords), reservedKeywords: reservedKeywords)
    }
}
