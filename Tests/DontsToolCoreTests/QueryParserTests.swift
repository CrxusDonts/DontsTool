import Testing
@testable import DontsToolCore

@Suite("QueryParser")
struct QueryParserTests {
    private let routes: [String: KeywordRoute] = [
        "json": KeywordRoute(providerID: "text", keyword: "json"),
        "tr": KeywordRoute(providerID: "translation", keyword: "tr")
    ]

    @Test func globalModeTrimsWhitespace() {
        let context = QueryParser.parse("  chrome  ", routes: routes)
        #expect(context.mode == .global)
        #expect(context.query == "chrome")
    }

    @Test func keywordModeIsCaseInsensitive() {
        let context = QueryParser.parse("JSON {\"a\":1}", routes: routes)
        #expect(context.mode == .keyword(providerID: "text", keyword: "json", argument: "{\"a\":1}"))
    }

    @Test func keywordWithEmptyArgument() {
        let context = QueryParser.parse("tr", routes: routes)
        #expect(context.mode == .keyword(providerID: "translation", keyword: "tr", argument: ""))
    }

    @Test func keywordArgumentKeepsInternalSpaces() {
        let context = QueryParser.parse("tr   hello world  ", routes: routes)
        #expect(context.mode == .keyword(providerID: "translation", keyword: "tr", argument: "hello world  "))
    }

    @Test func chineseQueryStaysGlobal() {
        let context = QueryParser.parse("微信", routes: routes)
        #expect(context.mode == .global)
        #expect(context.query == "微信")
    }
}
