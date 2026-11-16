import Foundation
import Testing
@testable import DontsToolCore

@Suite("Search engine keyword ownership")
@MainActor
struct SearchEngineKeywordRulesTests {
    @Test func configuredWebsiteKeywordCannotBeTakenByNewSearchEngine() {
        let current = SearchEngineConfiguration.builtIn
        var proposal = current
        proposal.engines.append(.init(id: "company", name: "公司文档", keyword: "wiki", urlTemplate: "https://example.com/?q={query}"))
        let reserved = SearchEngineKeywordRules.reservedKeywords(current: current, proposed: proposal, websiteKeywords: ["wiki"])
        #expect(throws: (any Error).self) { try proposal.validated(reservedKeywords: reserved) }
    }

    @Test func legacyGithubOverrideRemainsButDoesNotPermitAnotherEngineToTakeItsKeyword() throws {
        let current = SearchEngineConfiguration.builtIn
        let reserved = SearchEngineKeywordRules.reservedKeywords(current: current, proposed: current, websiteKeywords: ["gh"])
        #expect(try current.validated(reservedKeywords: reserved) == current)
        var proposal = current
        proposal.engines.removeAll { $0.id == "github" }
        proposal.engines.append(.init(id: "company", name: "代码", keyword: "gh", urlTemplate: "https://example.com/?q={query}"))
        let conflicting = SearchEngineKeywordRules.reservedKeywords(current: current, proposed: proposal, websiteKeywords: ["gh"])
        #expect(throws: (any Error).self) { try proposal.validated(reservedKeywords: conflicting) }
    }

    @Test func websiteEditsRejectLiveSearchKeywordWithoutChangingStoredConfiguration() throws {
        let name = "dontstool.website.reserved.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var searchKeywords: Set<String> = []
        let store = WebsiteShortcutStore(defaults: defaults, reservedKeywords: { searchKeywords })
        let proposed = WebsiteShortcutConfiguration(groups: [.init(keyword: "wiki", name: "文档")])
        try store.save(proposed)
        searchKeywords = ["docs"]
        let conflicting = WebsiteShortcutConfiguration(groups: [.init(keyword: "docs", name: "文档")])
        #expect(throws: (any Error).self) { try store.save(conflicting) }
        #expect(store.configuration == proposed)
        #expect(WebsiteShortcutStore(defaults: defaults).configuration == proposed)
    }

    @Test func releasedSearchKeywordCanBeUsedByWebsiteGroup() throws {
        let name = "dontstool.website.released.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WebsiteShortcutStore(defaults: defaults, reservedKeywords: { [] })
        let proposed = WebsiteShortcutConfiguration(groups: [.init(keyword: "g", name: "公司系统")])
        try store.save(proposed)
        #expect(store.configuration == proposed)
    }

    @Test func customGhSearchCannotBeTakenByLaterWebsiteGroup() {
        let name = "dontstool.website.customgh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WebsiteShortcutStore(defaults: defaults, reservedKeywords: { ["gh"] })
        let proposed = WebsiteShortcutConfiguration(groups: [.init(keyword: "gh", name: "公司系统")])
        #expect(throws: (any Error).self) { try store.save(proposed) }
        #expect(store.configuration.groups.isEmpty)
    }
}
