import Foundation

public enum SearchEngineKeywordRules {
    public static func reservedKeywords(current: SearchEngineConfiguration, proposed: SearchEngineConfiguration,
                                        websiteKeywords: Set<String>) -> Set<String> {
        var reserved = SearchEngineConfiguration.reservedKeywords.union(websiteKeywords)
        // Existing gh website groups keep priority over the built-in GitHub shortcut.
        if current.engines.contains(where: isLegacyGithub), proposed.engines.contains(where: isLegacyGithub) { reserved.remove("gh") }
        return reserved
    }

    public static func reservedWebsiteKeywords(for engines: SearchEngineConfiguration) -> Set<String> {
        var keywords = Set(engines.enabledEngines.map(\.keyword))
        if engines.enabledEngines.contains(where: isLegacyGithub) { keywords.remove("gh") }
        return keywords
    }

    private static func isLegacyGithub(_ engine: SearchEngineDefinition) -> Bool {
        engine.id == "github" && engine.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gh"
    }
}
