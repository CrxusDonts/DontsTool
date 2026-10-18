import Foundation
import Testing
@testable import DontsToolCore

@MainActor private final class WindowCatalogHarness: ToolDocumentProviding {
    let store = ToolDocumentStore()
    var toolDocuments: [ToolDocument] { store.openDocuments }
    func openTool(_ request: ToolOpenRequest) { store.create(request) }
    func activateDocument(_ id: UUID) { store.activate(id) }
}
@Suite("具名窗口搜索") @MainActor
struct ToolDocumentDiscoveryTests {
    @Test(arguments: [ToolKind.timestamp, .translation])
    func toolEntrySurvivesManyMatchingTextAndTranslationWindows(kind: ToolKind) async throws {
        let opener = WindowCatalogHarness()
        let query = kind == .timestamp ? "时间戳" : "翻译"
        let entryKey = kind == .timestamp ? "tool:timestamp" : "tool:translation"
        for index in 0..<16 {
            let document = opener.store.create(ToolOpenRequest(kind: index.isMultiple(of: 2) ? .timestamp : .translation, input: "草稿 \(index)"))
            opener.store.rename(document.id, to: "\(query) 草稿 \(index)")
        }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [
            TextToolsProvider(settings: settings, toolOpener: opener),
            TranslationProvider(settings: settings, toolOpener: opener)
        ]), slowDelay: .zero)
        var results: [SearchItem] = []
        coordinator.onUpdate = { results = $0.items }

        coordinator.submit(query)
        await coordinator.waitForPendingSearch()

        #expect(results.filter { $0.group == .tool }.count == 8)
        #expect(results.contains { $0.canonicalKey.hasPrefix("window:") })
        let entry = try #require(results.first { $0.canonicalKey == entryKey })
        try await entry.primaryAction?.run()
        #expect(opener.store.openDocuments.count == 17)
        #expect(opener.store.openDocuments.first?.kind == kind)
        #expect(opener.store.openDocuments.first?.session.input.isEmpty == true)
    }

    @Test func searchSelectsTheRightDocumentWithoutCreatingOrReplacing() async throws {
        let opener = WindowCatalogHarness()
        let one = opener.store.create(ToolOpenRequest(kind: .json, input: "{\"one\":1}"))
        let two = opener.store.create(ToolOpenRequest(kind: .json, input: "{\"two\":2}"))
        opener.store.rename(one.id, to: "订单接口测试")
        opener.store.rename(two.id, to: "订单接口线上")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let provider = TextToolsProvider(settings: settings, toolOpener: opener)
        let results = await provider.search(SearchContext(rawQuery: "订单接口测试", mode: .global))
        #expect(results.count == 1)
        try await results[0].primaryAction?.run()
        #expect(opener.store.openDocuments.first?.id == one.id)
        #expect(opener.store.documents.count == 2)
        #expect(two.session.input == "{\"two\":2}")
    }
    @Test func explicitToolEntryCreatesFreshWindowAndClosedTitlesAreNotSearchable() async throws {
        let opener = WindowCatalogHarness()
        let old = opener.store.create(ToolOpenRequest(kind: .json, input: "true"))
        opener.store.rename(old.id, to: "旧窗口")
        let provider = TextToolsProvider(settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!), toolOpener: opener)
        let results = await provider.search(SearchContext(rawQuery: "json false", mode: .keyword(providerID: "text", keyword: "json", argument: "false")))
        try await results[0].primaryAction?.run()
        #expect(opener.store.openDocuments.count == 2)
        #expect(old.session.input == "true")
        #expect(opener.store.openDocuments.first?.session.input == "false")
        opener.store.close(old.id)
        #expect(await provider.search(SearchContext(rawQuery: "旧窗口", mode: .global)).isEmpty)
    }
}
