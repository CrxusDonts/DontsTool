import Foundation
import Testing
@testable import DontsToolCore

@MainActor final class MockToolOpener: ToolOpening {
    var requests: [ToolOpenRequest] = []
    func openTool(_ request: ToolOpenRequest) { requests.append(request) }
}
@Suite("工具窗口入口") @MainActor
struct TextToolsProviderTests {
    @Test func opensEditorWithoutTransformingOrCopying() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let opener = MockToolOpener()
        let provider = TextToolsProvider(settings: SettingsStore(defaults: defaults), toolOpener: opener)
        let items = await provider.search(SearchContext(rawQuery: "json nope", mode: .keyword(providerID: "text", keyword: "json", argument: "nope")))
        #expect(items[0].title == "JSON 工具")
        try await items[0].primaryAction?.run()
        #expect(opener.requests.first?.kind == .json)
        #expect(opener.requests.first?.input == "nope")
    }
    @Test func discoverByChineseAndDecoderAlias() async throws {
        let opener = MockToolOpener()
        let provider = TextToolsProvider(settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!), toolOpener: opener)
        let found = await provider.search(SearchContext(rawQuery: "哈希", mode: .global))
        #expect(found.count == 1)
        let items = await provider.search(SearchContext(rawQuery: "b64d", mode: .keyword(providerID: "text", keyword: "b64d", argument: "")))
        try await items[0].primaryAction?.run()
        #expect(opener.requests.first?.mode == "decode")
        #expect(opener.requests.first?.input == nil)
    }
    @Test func parserPreservesTrailingContent() {
        let route = KeywordRoute(providerID: "text", keyword: "b64")
        let context = QueryParser.parse("b64 hello \n", routes: ["b64": route])
        #expect(context.query == "hello \n")
    }
}
