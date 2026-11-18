import DontsToolCore
import Foundation

struct ShortcutJSONDraft: Identifiable {
    let id = UUID()
    let text: String
}

enum ShortcutAddressMode: String, CaseIterable, Identifiable, Sendable {
    case single = "单个网址"
    case environments = "多个环境"
    var id: Self { self }
}

struct ShortcutEnvironmentDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    var key: String = ""
    var name: String = ""
    var url: String = ""
    var aliases: String = ""

    static let startingRows: [Self] = [
        .init(key: "test", name: "测试"),
        .init(key: "prod", name: "生产"),
    ]
}

struct ShortcutPageDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    var key: String = ""
    var name: String = ""
    var path: String = ""
    var aliases: String = ""
    var urls: [String: String] = [:]

    static func environmentKeys(_ keys: [String]) -> [String] {
        Array(Set(keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
    }
}

struct ShortcutFormDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    var groupIndex: Int?
    var itemIndex: Int?
    var isGroup: Bool
    var keyword: String = ""
    var name: String = ""
    var url: String = ""
    var aliases: String = ""
    var addressMode: ShortcutAddressMode = .single
    var environments: [ShortcutEnvironmentDraft] = ShortcutEnvironmentDraft.startingRows
    var pages: [ShortcutPageDraft] = []

    static func group(index: Int? = nil, value: WebsiteShortcutGroup? = nil) -> Self {
        .init(groupIndex: index, isGroup: true, keyword: value?.keyword ?? "", name: value?.name ?? "")
    }

    static func item(group: Int, index: Int? = nil, value: WebsiteShortcut? = nil) -> Self {
        let environments = value?.environments ?? []
        return .init(
            groupIndex: group, itemIndex: index, isGroup: false,
            keyword: value?.key ?? "", name: value?.name ?? "", url: value?.url ?? "",
            aliases: value?.aliases.joined(separator: "\n") ?? "",
            addressMode: environments.isEmpty ? .single : .environments,
            environments: environments.isEmpty ? ShortcutEnvironmentDraft.startingRows : environments.map {
                .init(key: $0.key, name: $0.name, url: $0.url, aliases: $0.aliases.joined(separator: "\n"))
            },
            pages: (value?.pages ?? []).map {
                .init(key: $0.key, name: $0.name, path: $0.path, aliases: $0.aliases.joined(separator: "\n"), urls: $0.urls)
            }
        )
    }

    func proposal(in configuration: WebsiteShortcutConfiguration) -> WebsiteShortcutConfiguration {
        var config = configuration
        if isGroup {
            if let index = groupIndex {
                config.groups[index].keyword = keyword; config.groups[index].name = name
            } else { config.groups.append(.init(keyword: keyword, name: name)) }
        } else if let index = groupIndex {
            let environments: [WebsiteShortcutEnvironment] = addressMode == .environments ? self.environments.map {
                .init(key: $0.key, name: $0.name, url: $0.url, aliases: aliases($0.aliases))
            } : []
            if !pages.isEmpty { config.version = max(config.version, 3) }
            else if addressMode == .environments { config.version = max(config.version, 2) }
            let item = WebsiteShortcut(
                key: keyword, name: name,
                url: addressMode == .single ? url : "", aliases: aliases(self.aliases),
                environments: environments,
                pages: pages.map { .init(key: $0.key, name: $0.name, path: $0.path, aliases: aliases($0.aliases), urls: $0.urls) }
            )
            if let offset = itemIndex { config.groups[index].items[offset] = item }
            else { config.groups[index].items.append(item) }
        }
        return config
    }

    private func aliases(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
