import Foundation

@MainActor
public final class ToolRegistry {
    public let providers: [ToolProvider]

    public init(providers: [ToolProvider]) {
        self.providers = providers
    }

    public var enabledProviders: [ToolProvider] {
        providers.filter(\.isEnabled)
    }

    public func provider(for id: String) -> ToolProvider? {
        providers.first { $0.id == id }
    }

    public func enabledKeywordRoutes() -> [String: KeywordRoute] {
        var routes: [String: KeywordRoute] = [:]
        let ordered = providers
            .filter(\.isEnabled)
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.id < $1.id
            }

        for provider in ordered {
            for keyword in provider.keywords {
                let normalized = keyword.lowercased()
                if let existing = routes[normalized] {
                    Log.provider.warning(
                        "关键词冲突: \(normalized, privacy: .public) 已被 \(existing.providerID, privacy: .public) 占用，忽略 \(provider.id, privacy: .public)"
                    )
                    continue
                }
                routes[normalized] = KeywordRoute(providerID: provider.id, keyword: normalized)
            }
        }
        return routes
    }
}
