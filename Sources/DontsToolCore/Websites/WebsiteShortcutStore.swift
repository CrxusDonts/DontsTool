import Combine
import Foundation

@MainActor
public final class WebsiteShortcutStore: ObservableObject {
    @Published public private(set) var configuration: WebsiteShortcutConfiguration = .empty
    @Published public private(set) var loadError: String?
    private let defaults: UserDefaults
    private static let key = "dontstool.websiteShortcuts"
    private var damagedJSON: String?
    public var editableJSON: String { damagedJSON ?? (try? configuration.json()) ?? "" }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        let data = Data(try validated.json().utf8)
        defaults.set(data, forKey: Self.key)
        damagedJSON = nil
        loadError = nil
        configuration = validated
    }

    public func importJSON(_ text: String) throws { try save(WebsiteShortcutConfiguration.decode(text)) }
}
