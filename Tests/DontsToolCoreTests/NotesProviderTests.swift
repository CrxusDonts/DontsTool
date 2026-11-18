import Foundation
import Testing
@testable import DontsToolCore

@MainActor private final class NotesTestOpener: LocalNoteOpening {
    var created = 0
    var createdTexts: [String] = []
    var capturedTexts: [String] = []
    var opened: [UUID] = []
    private let store: LocalNoteStore?

    init(store: LocalNoteStore? = nil) {
        self.store = store
    }

    func createNote() { created += 1 }
    func createNote(with text: String) { createdTexts.append(text) }
    @discardableResult
    func quickCapture(_ text: String) throws -> LocalNoteRecord {
        capturedTexts.append(text)
        if let store {
            return try store.appendQuickCapture(text)
        }
        return LocalNoteRecord(title: LocalNoteStore.dailyNoteTitle(), titleIsAutomatic: false)
    }
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
    private func withFixture(_ body: (SettingsStore, LocalNoteStore, NotesTestOpener, MockClipboard, MockFeedback) async throws -> Void) async throws {
        let name = "NotesProviderTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let store = LocalNoteStore(rootURL: root)
        try await body(SettingsStore(defaults: defaults), store, NotesTestOpener(store: store), MockClipboard(), MockFeedback())
    }

    @Test func globalDiscoveryShowsOnlyEntryAndNeverExposesNoteContent() async throws {
        try await withFixture { settings, store, opener, _, _ in
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

    @Test func scopedSearchPrioritizesMatchesThenQuickCaptureAndExposesLightActions() async throws {
        try await withFixture { settings, store, opener, clipboard, feedback in
            let pinned = try store.create(title: "pinned")
            let recent = try store.create(title: "recent")
            let body = LocalNoteContent(
                json: "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"needle in body\"}]}]}",
                markdown: "**needle** in body",
                plainText: "needle in body"
            )
            _ = try store.updateContent(pinned.id, content: body)
            _ = try store.setPinned(pinned.id, pinned: true)
            let provider = NotesProvider(settings: settings, store: store, opener: opener, clipboard: clipboard, feedback: feedback)

            let empty = await provider.search(SearchContext(rawQuery: "note", mode: .keyword(providerID: "notes", keyword: "note", argument: "")))
            #expect(empty.count == 3)
            #expect(empty.map(\.title) == ["新建空白便笺", "pinned", "recent"])

            let found = await provider.search(SearchContext(rawQuery: "note needle", mode: .keyword(providerID: "notes", keyword: "note", argument: "needle")))
            #expect(found.count == 3)
            #expect(found[0].title == "pinned")
            #expect(found[1].canonicalKey == "notes:quick-capture")
            #expect(found[2].canonicalKey == "notes:create-with-text")

            let matched = found[0]
            #expect(matched.primaryAction?.presentation == .openWindow)
            #expect(matched.actions.map(\.id) == ["notes.open", "notes.copyPlain", "notes.copyMarkdown", "notes.pin", "notes.trash"])
            try await matched.primaryAction?.run()
            #expect(opener.opened == [pinned.id])
            try await matched.secondaryAction?.run()
            #expect(clipboard.written.last == "needle in body")
            try await matched.actions[2].run()
            #expect(clipboard.written.last == "**needle** in body")
            try await matched.actions[3].run()
            #expect(store.note(pinned.id)?.isPinned == false)
            try await matched.actions[4].run()
            #expect(store.note(pinned.id) == nil)
            #expect(!feedback.messages.isEmpty)
        }
    }

    @Test func unmatchedScopedQueryPlacesQuickCaptureFirstWithCreateWithTextSecondary() async throws {
        try await withFixture { settings, store, opener, clipboard, feedback in
            _ = try store.create(title: "unrelated")
            let provider = NotesProvider(settings: settings, store: store, opener: opener, clipboard: clipboard, feedback: feedback)
            let items = await provider.search(SearchContext(rawQuery: "note 排查 Redis 超时", mode: .keyword(providerID: "notes", keyword: "note", argument: "排查 Redis 超时")))
            #expect(items.count == 2)
            #expect(items[0].canonicalKey == "notes:quick-capture")
            #expect(items[0].primaryAction?.presentation == .dismissThenRun)
            #expect(items[0].secondaryAction?.presentation == .openWindow)

            try await items[0].primaryAction?.run()
            #expect(opener.capturedTexts == ["排查 Redis 超时"])
            #expect(feedback.messages.last?.contains("速记") == true)

            try await items[0].secondaryAction?.run()
            #expect(opener.createdTexts == ["排查 Redis 超时"])
        }
    }

    @Test func occupiedKeywordPreservesExistingRoutesAndChineseDiscovery() async throws {
        try await withFixture { settings, store, opener, _, _ in
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
        try await withFixture { settings, store, opener, _, _ in
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
            #expect(filtered.map(\.title).first == "既有便笺")
        }
    }

    @Test func allCandidateKeywordsRespectUnavailableNormalization() async throws {
        try await withFixture { settings, store, opener, _, _ in
            let provider = NotesProvider(settings: settings, store: store, opener: opener, unavailableKeywords: { [" NOTE ", " 便笺 "] })
            #expect(provider.keywords.isEmpty)
            #expect(ToolRegistry(providers: [provider]).enabledKeywordRoutes().isEmpty)
            let global = await provider.search(SearchContext(rawQuery: "便笺", mode: .global))
            #expect(global.count == 1)
            #expect(global.first?.keyword == nil)
        }
    }

    @Test func disabledProviderAndPreviouslyReturnedActionsStayDisabled() async throws {
        try await withFixture { settings, store, opener, _, _ in
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
        try await withFixture { settings, store, opener, _, _ in
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
