import Foundation
import Testing
@testable import DontsToolCore

@Suite("Gemini provider")
@MainActor
struct GeminiProviderTests {
    private func fixture(installed: Bool = true) -> (GeminiProvider, SettingsStore, GeminiTestService, MockFeedback) {
        let defaults = UserDefaults(suiteName: "dontstool.gemini.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.setProviderEnabled("gemini", to: true)
        let index = AppIndex()
        if installed {
            index.setAppsForTesting([AppEntry(id: "gemini", displayName: "Gemini", bundleID: "com.google.GeminiMacOS",
                url: URL(fileURLWithPath: "/Applications/Gemini.app"), modifiedAt: nil)])
        }
        let service = GeminiTestService()
        let feedback = MockFeedback()
        return (GeminiProvider(index: index, settings: settings, service: service, feedback: feedback), settings, service, feedback)
    }

    @Test func typingDoesNotOpenOrTransmitAndExecutionPreservesTheQuestion() async throws {
        let (provider, _, service, _) = fixture()
        let query = "gm 解释 actor\n保留换行  "
        let context = QueryParser.parse(query, routes: ToolRegistry(providers: [provider]).enabledKeywordRoutes())
        let items = await provider.search(context)
        #expect(service.questions.isEmpty)
        #expect(service.opened.isEmpty)
        let item = try #require(items.first)
        try await item.primaryAction?.run()
        #expect(service.questions == ["解释 actor\n保留换行  "])
        #expect(service.destinations == [URL(fileURLWithPath: "/Applications/Gemini.app")])
        try await item.secondaryAction?.run()
        #expect(service.opened.count == 1)
        #expect(service.questions.count == 1)
    }

    @Test func ordinarySearchNeverCallsGemini() async {
        let (provider, _, service, _) = fixture()
        #expect(!provider.supportsGlobalSearch)
        #expect(await provider.search(SearchContext(rawQuery: "question", mode: .global)).isEmpty)
        #expect(service.questions.isEmpty)
    }

    @Test func disablingAfterSearchPreventsExecution() async throws {
        let (provider, settings, service, _) = fixture()
        let context = SearchContext(rawQuery: "gm question", mode: .keyword(providerID: provider.id, keyword: "gm", argument: "question"))
        let items = await provider.search(context)
        settings.setProviderEnabled(provider.id, to: false)
        try await items.first?.primaryAction?.run()
        try await items.first?.secondaryAction?.run()
        #expect(service.questions.isEmpty)
        #expect(service.opened.isEmpty)
    }

    @Test func bareKeywordOnlyOpensTheApp() async throws {
        let (provider, _, service, _) = fixture()
        let context = QueryParser.parse("gemini", routes: ToolRegistry(providers: [provider]).enabledKeywordRoutes())
        let item = try #require(await provider.search(context).first)
        try await item.primaryAction?.run()
        #expect(service.questions.isEmpty)
        #expect(service.opened.count == 1)
    }

    @Test func absentAppShowsAnActionableHintWithoutTransmitting() async {
        let (provider, _, service, _) = fixture(installed: false)
        let context = QueryParser.parse("gm question", routes: ToolRegistry(providers: [provider]).enabledKeywordRoutes())
        let items = await provider.search(context)
        #expect(items.first?.title == "未找到 Gemini 应用")
        #expect(service.questions.isEmpty)
    }
}

@MainActor
private final class GeminiTestService: GeminiAsking {
    var questions: [String] = []
    var destinations: [URL] = []
    var opened: [URL] = []
    func ask(_ question: String, in application: URL) async throws { questions.append(question); destinations.append(application) }
    func open(in application: URL) async throws { opened.append(application) }
}
