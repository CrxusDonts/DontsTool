import Combine
import Foundation

@MainActor
public final class WebsiteShortcutStore: ObservableObject {
    @Published public private(set) var configuration: WebsiteShortcutConfiguration = .empty
    @Published public private(set) var loadError: String?
    private let defaults: UserDefaults
    private let reservedKeywords: @MainActor () -> Set<String>
    private static let key = "dontstool.websiteShortcuts"
    private var damagedJSON: String?
    public var editableJSON: String { damagedJSON ?? (try? configuration.json()) ?? "" }

    public init(defaults: UserDefaults = .standard,
                reservedKeywords: @escaping @MainActor () -> Set<String> = { SearchEngineKeywordRules.reservedWebsiteKeywords(for: .builtIn) }) {
        self.defaults = defaults
        self.reservedKeywords = reservedKeywords
        if let data = defaults.data(forKey: Self.key) {
            do { configuration = try WebsiteShortcutConfiguration.decode(String(decoding: data, as: UTF8.self)) }
            catch {
                loadError = "网址配置加载失败：\(error.localizedDescription)。原配置已保留，可在 JSON 配置中修复。"
                damagedJSON = String(decoding: data, as: UTF8.self)
            }
        }
    }

    public func save(_ proposed: WebsiteShortcutConfiguration) throws {
        let validated = try proposed.validated()
        let occupied = reservedKeywords()
        if let conflict = validated.groups.first(where: { occupied.contains($0.keyword) }) {
            throw ActionError.invalidInput("快捷词 \(conflict.keyword) 已被搜索引擎占用，请换一个")
        }
        let data = Data(try validated.json().utf8)
        defaults.set(data, forKey: Self.key)
        damagedJSON = nil
        loadError = nil
        configuration = validated
    }

    public func importJSON(_ text: String) throws { try save(WebsiteShortcutConfiguration.decode(text)) }
}
