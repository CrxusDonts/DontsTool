import Foundation
import Testing
@testable import DontsToolCore

@MainActor private final class NotesTestOpener: LocalNoteOpening {
    var created = 0
    var opened: [UUID] = []
    func createNote() { created += 1 }
    func openNote(_ id: UUID) { opened.append(id) }
}

@MainActor private final class NotesTestKeywords {
    var unavailable: Set<String> = ["NOTE"]
}

@MainActor private final class NotesExistingPrefixProvider: ToolProvider {
    let id = "existing-config"
    let displayName = "既有配置"
    let keywords = ["note"]
    let priority = 300
    var isEnabled = true
    func search(_ context: SearchContext) async -> [SearchItem] { [] }
}

@Suite("便笺搜索入口") @MainActor
struct NotesProviderTests {
    private func withFixture(_ body: (SettingsStore, LocalNoteStore, NotesTestOpener) async throws -> Void) async throws {
        let name = "NotesProviderTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(SettingsStore(defaults: defaults), LocalNoteStore(rootURL: root), NotesTestOpener())
    }

    @Test func globalDiscoveryShowsOnlyEntryAndNeverExposesNoteContent() async throws {
        try await withFixture { settings, store, opener in
            _ = try store.create(title: "private secret")
            let provider = NotesProvider(settings: settings, store: store, opener: opener)
            let privateQuery = await provider.search(SearchContext(rawQuery: "private secret", mode: .global))
            #expect(privateQuery.isEmpty)
            let chinese = await provider.search(SearchContext(rawQuery: "便笺", mode: .global))
            #expect(chinese.count == 1)
            let entry = try #require(chinese.first)
            #expect(entry.group == .tool)
            #expect(entry.primaryAction?.presentation == .openWindow)
            #expect(!entry.title.contains("secret"))
            #expect(entry.subtitle?.contains("secret") != true)
            #expect(opener.created == 0)
            try await entry.primaryAction?.run()
            #expect(opener.created == 1)
            let all = await provider.search(SearchContext(rawQuery: "", mode: .global))
            #expect(all.count == 1)
        }
    }

    @Test func scopedSearchFindsBodyAndPinnedRecentNotesWithWindowActions() async throws {
        try await withFixture { settings, store, opener in
            let pinned = try store.create(title: "pinned")
            let recent = try store.create(title: "recent")
            _ = try store.updateContent(pinned.id, content: LocalNoteContent(json: "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"needle in body\"}]}]}", markdown: "needle in body", plainText: "needle in body"))
            _ = try store.setPinned(pinned.id, pinned: true)
            let provider = NotesProvider(settings: settings, store: store, opener: opener)
            let empty = await provider.search(SearchContext(rawQuery: "note", mode: .keyword(providerID: "notes", keyword: "note", argument: "")))
            #expect(empty.count == 3)
            #expect(empty.map(\.title) == ["新建便笺", "pinned", "recent"])
            let found = await provider.search(SearchContext(rawQuery: "note needle", mode: .keyword(providerID: "notes", keyword: "note", argument: "needle")))
            #expect(found.map(\.title) == ["新建便笺", "pinned"])
            let result = try #require(found.last)
            #expect(result.primaryAction?.presentation == .openWindow)
            try await result.primaryAction?.run()
            #expect(opener.opened == [pinned.id])
            try store.trash(recent.id)
            let afterTrash = await provider.search(SearchContext(rawQuery: "note", mode: .keyword(providerID: "notes", keyword: "note", argument: "")))
            #expect(afterTrash.count == 2)
        }
    }

    @Test func occupiedKeywordPreservesExistingRoutesAndChineseDiscovery() async throws {
        try await withFixture { settings, store, opener in
            let keywords = NotesTestKeywords()
            let provider = NotesProvider(settings: settings, store: store, opener: opener, unavailableKeywords: { keywords.unavailable })
            #expect(provider.keywords == ["便笺"])
            let registry = ToolRegistry(providers: [provider])
            #expect(registry.enabledKeywordRoutes()["note"] == nil)
            let entry = await provider.search(SearchContext(rawQuery: "便笺", mode: .global))
            #expect(entry.count == 1)
            #expect(entry.first?.keyword == "便笺")
            keywords.unavailable = []
            #expect(provider.keywords == ["note", "便笺"])
            #expect(registry.enabledKeywordRoutes()["note"]?.providerID == "notes")
        }
    }

    @Test func chineseRouteReopensPersistedNotesWhenExistingConfigurationOwnsNote() async throws {
        try await withFixture { settings, store, opener in
            let saved = try store.create(title: "既有便笺")
            let restarted = LocalNoteStore(rootURL: store.rootURL)
            let provider = NotesProvider(settings: settings, store: restarted, opener: opener, unavailableKeywords: { ["NOTE"] })
            let registry = ToolRegistry(providers: [NotesExistingPrefixProvider(), provider])
            let routes = registry.enabledKeywordRoutes()
            #expect(routes["note"]?.providerID == "existing-config")
            #expect(routes["便笺"]?.providerID == "notes")
            #expect(QueryParser.parse("note", routes: routes).mode == .keyword(providerID: "existing-config", keyword: "note", argument: ""))
            let context = QueryParser.parse("便笺", routes: routes)
            let results = await provider.search(context)
            let existing = try #require(results.first(where: { $0.title == "既有便笺" }))
            try await existing.primaryAction?.run()
            #expect(opener.opened == [saved.id])
            let filtered = await provider.search(QueryParser.parse("便笺 既有", routes: routes))
            #expect(filtered.map(\.title) == ["新建便笺", "既有便笺"])
        }
    }

    @Test func allCandidateKeywordsRespectUnavailableNormalization() async throws {
        try await withFixture { settings, store, opener in
            let provider = NotesProvider(settings: settings, store: store, opener: opener, unavailableKeywords: { [" NOTE ", " 便笺 "] })
            #expect(provider.keywords.isEmpty)
            #expect(ToolRegistry(providers: [provider]).enabledKeywordRoutes().isEmpty)
            let global = await provider.search(SearchContext(rawQuery: "便笺", mode: .global))
            #expect(global.count == 1)
            #expect(global.first?.keyword == nil)
        }
    }

    @Test func disabledProviderAndPreviouslyReturnedActionsStayDisabled() async throws {
        try await withFixture { settings, store, opener in
            let record = try store.create()
            let provider = NotesProvider(settings: settings, store: store, opener: opener)
            let entry = try #require(await provider.search(SearchContext(rawQuery: "便笺", mode: .global)).first)
            let scoped = await provider.search(SearchContext(rawQuery: "note", mode: .keyword(providerID: "notes", keyword: "note", argument: "")))
            let open = try #require(scoped.first(where: { $0.title == record.title }))
            provider.isEnabled = false
            #expect(await provider.search(SearchContext(rawQuery: "便笺", mode: .global)).isEmpty)
            try await entry.primaryAction?.run()
            try await open.primaryAction?.run()
            #expect(opener.created == 0)
            #expect(opener.opened.isEmpty)
            #expect(!settings.isProviderEnabled("notes"))
        }
    }

    @Test func trashedNoteCannotBeOpenedByStaleSearchResult() async throws {
        try await withFixture { settings, store, opener in
            let record = try store.create(title: "note to delete")
            let provider = NotesProvider(settings: settings, store: store, opener: opener)
            let scoped = await provider.search(SearchContext(rawQuery: "note", mode: .keyword(providerID: "notes", keyword: "note", argument: "")))
            let result = try #require(scoped.first(where: { $0.title == record.title }))
            try store.trash(record.id)
            try await result.primaryAction?.run()
            #expect(opener.opened.isEmpty)
        }
    }
}
