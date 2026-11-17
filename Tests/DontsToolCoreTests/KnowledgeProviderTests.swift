import Foundation
import Testing
@testable import DontsToolCore

@MainActor private final class KnowledgeServiceSpy: KnowledgeServing {
    var requests: [KnowledgeOpenRequest] = []
    var queries: [String] = []
    var statusNotice: String?
    var results: [KnowledgeSearchResult] = []
    var error: Error?
    var onSearch: (() -> Void)?
    func openKnowledge(_ request: KnowledgeOpenRequest) { requests.append(request) }
    func searchKnowledge(_ query: String) async throws -> [KnowledgeSearchResult] {
        queries.append(query)
        onSearch?()
        if let error { throw error }
        return results
    }
}

@Suite("知识库原生插件入口") @MainActor
struct KnowledgeProviderTests {
    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }
    private func keyword(_ keyword: String, _ argument: String = "") -> SearchContext {
        SearchContext(rawQuery: keyword + " " + argument, mode: .keyword(providerID: "knowledge", keyword: keyword, argument: argument))
    }

    @Test func emptyGlobalQueryOffersThreeEntriesWithoutServiceSearchOrOpen() async throws {
        let service = KnowledgeServiceSpy()
        let provider = KnowledgeProvider(settings: settings(), service: service)
        let items = await provider.search(.init(rawQuery: "", mode: .global))
        #expect(items.count == 3)
        #expect(service.queries.isEmpty)
        #expect(service.requests.isEmpty)
        for item in items { #expect(item.primaryAction?.presentation == .openWindow) }
        for item in items { try await item.primaryAction?.run() }
        #expect(service.requests.map(\.surface) == [.search, .capture, .inbox])
    }

    @Test func configuredScopedSearchMapsDocumentsAndOpensEditor() async throws {
        let settings = settings()
        settings.setKnowledgeBaseURL("https://kb.example.com")
        let service = KnowledgeServiceSpy()
        service.results = [.init(id: "article-1", title: "中文文档", excerpt: "命中的内容")]
        let provider = KnowledgeProvider(settings: settings, service: service)
        let items = await provider.search(keyword("kb", "中文 + swift"))
        #expect(service.queries == ["中文 + swift"])
        #expect(items.first?.title == "中文文档")
        #expect(items.first?.subtitle == "命中的内容")
        #expect(items.first?.group == .knowledge)
        #expect(service.requests.isEmpty)
        try await items.first?.primaryAction?.run()
        #expect(service.requests == [.init(surface: .editor, documentID: "article-1")])
    }

    @Test func unconfiguredAndFailedSearchOpenPluginSearchWithOriginalQuery() async throws {
        let settings = settings()
        let service = KnowledgeServiceSpy()
        let provider = KnowledgeProvider(settings: settings, service: service)
        var items = await provider.search(keyword("kb", "private query"))
        #expect(service.queries.isEmpty)
        try await items.first?.primaryAction?.run()
        #expect(service.requests.last == .init(surface: .search, query: "private query"))
        settings.setKnowledgeBaseURL("https://kb.example.com")
        service.error = URLError(.userAuthenticationRequired)
        items = await provider.search(keyword("kb", "private query"))
        #expect(items.count == 1)
        try await items.first?.primaryAction?.run()
        #expect(service.requests.last == .init(surface: .search, query: "private query"))
    }

    @Test func capturePrefillRemainsRawAndRequiresActionBeforeOpening() async throws {
        let service = KnowledgeServiceSpy()
        let provider = KnowledgeProvider(settings: settings(), service: service)
        let text = "https://example.com/a?secret=中文\n草稿内容  "
        let items = await provider.search(keyword("collect", text))
        #expect(service.requests.isEmpty)
        #expect(service.queries.isEmpty)
        try await items.first?.primaryAction?.run()
        #expect(service.requests == [.init(surface: .capture, query: text)])
        let inbox = await provider.search(keyword("inbox", "ignored"))
        try await inbox.first?.primaryAction?.run()
        #expect(service.requests.last == .init(surface: .inbox))
    }

    @Test func scopedNoticeDoesNotLeakIntoEntryOnlyQueries() async {
        let settings = settings()
        settings.setKnowledgeBaseURL("https://kb.example.com")
        let service = KnowledgeServiceSpy()
        service.statusNotice = "请先在知识库窗口登录"
        service.error = URLError(.userAuthenticationRequired)
        let provider = KnowledgeProvider(settings: settings, service: service)
        let entries = [
            SearchContext(rawQuery: "", mode: .global),
            SearchContext(rawQuery: "知识库", mode: .global),
            keyword("collect", "draft"), keyword("inbox"), keyword("kb")
        ]
        for entry in entries {
            _ = await provider.search(keyword("kb", "document"))
            #expect(provider.statusNotice == "请先在知识库窗口登录")
            let count = service.queries.count
            _ = await provider.search(entry)
            #expect(provider.statusNotice == nil)
            #expect(service.queries.count == count)
        }
    }

    @Test func disablingInvalidatesPreviouslyReturnedEntryAndDocumentActions() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        settings.setKnowledgeBaseURL("https://kb.example.com")
        let service = KnowledgeServiceSpy()
        service.results = [.init(id: "article", title: "文章", excerpt: nil)]
        let provider = KnowledgeProvider(settings: settings, service: service)
        let entries = await provider.search(.init(rawQuery: "", mode: .global))
        let documents = await provider.search(keyword("kb", "文章"))
        provider.isEnabled = false
        for item in entries + documents { try await item.primaryAction?.run() }
        #expect(service.requests.isEmpty)
        #expect(await provider.search(keyword("inbox")).isEmpty)
        #expect(await provider.search(keyword("collect", "片段")).isEmpty)
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.isProviderEnabled(ProviderID.knowledge.rawValue) == false)
    }

    @Test func disabledDuringSearchDoesNotReturnDocumentsOrFallbackEntry() async {
        let settings = settings()
        settings.setKnowledgeBaseURL("https://kb.example.com")
        let service = KnowledgeServiceSpy()
        let provider = KnowledgeProvider(settings: settings, service: service)
        service.results = [.init(id: "article", title: "文章", excerpt: nil)]
        service.onSearch = { provider.isEnabled = false }
        #expect(await provider.search(keyword("kb", "文章")).isEmpty)
        provider.isEnabled = true
        service.error = URLError(.cancelled)
        #expect(await provider.search(keyword("kb", "文章")).isEmpty)
    }

    @Test func disabledOrUnrelatedQueriesDoNotTouchService() async {
        let service = KnowledgeServiceSpy()
        let provider = KnowledgeProvider(settings: settings(), service: service)
        #expect(await provider.search(.init(rawQuery: "random thing", mode: .global)).isEmpty)
        #expect(await provider.search(.init(rawQuery: "tr words", mode: .keyword(providerID: "translation", keyword: "tr", argument: "words"))).isEmpty)
        provider.isEnabled = false
        #expect(await provider.search(keyword("kb", "query")).isEmpty)
        #expect(service.requests.isEmpty)
        #expect(service.queries.isEmpty)
    }
}
