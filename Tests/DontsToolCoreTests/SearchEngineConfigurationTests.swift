import Foundation
import Testing
@testable import DontsToolCore

@Suite("Search engine configuration")
struct SearchEngineConfigurationTests {
    private func engine(_ template: String = "https://search.example/?q={query}", id: String = "custom", keyword: String = "find") -> SearchEngineDefinition {
        .init(id: id, name: "搜索", keyword: keyword, urlTemplate: template)
    }

    private func configuration(_ engines: [SearchEngineDefinition], defaultID: String = "custom") -> SearchEngineConfiguration {
        .init(defaultEngineID: defaultID, engines: engines)
    }

    @Test func builtInsRoundTripAndRetainSearchDestinations() throws {
        let value = try SearchEngineConfiguration.builtIn.validated()
        #expect(value.defaultEngine.id == "google")
        #expect(value.enabledEngines.map(\.id) == ["google", "bing", "baidu", "ddg", "github"])
        #expect(value.engines.map(\.keyword) == ["g", "bing", "bd", "ddg", "gh"])
        #expect(value.engines.map { $0.searchURL(for: "a b")?.absoluteString } == [
            "https://www.google.com/search?q=a%20b", "https://www.bing.com/search?q=a%20b",
            "https://www.baidu.com/s?wd=a%20b", "https://duckduckgo.com/?q=a%20b", "https://github.com/search?q=a%20b"
        ])
        #expect(try SearchEngineConfiguration.decode(value.json()) == value)
    }

    @Test func queryIsUTF8EncodedOnceAcrossRepeatedPathQueryAndFragmentPlaceholders() throws {
        let value = engine("https://search.example/{query}?fixed=a%2Fb&q={query}#part-{query}")
        let url = try #require(value.searchURL(for: "中文 &#+?/%"))
        let encoded = "%E4%B8%AD%E6%96%87%20%26%23%2B%3F%2F%25"
        #expect(url.absoluteString == "https://search.example/\(encoded)?fixed=a%2Fb&q=\(encoded)#part-\(encoded)")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == "中文 &#+?/%")
        #expect(engine().searchURL(for: "AZaz09-._~%2F")?.absoluteString == "https://search.example/?q=AZaz09-._~%252F")
    }

    @Test func normalizationAndDisabledEnginesRetainStableIDs() throws {
        var disabled = engine(id: "other", keyword: "other")
        disabled.isEnabled = false
        var main = engine(keyword: " FIND ")
        main.name = " 搜索引擎 "
        let value = try configuration([main, disabled]).validated()
        #expect(value.engines[0].keyword == "find")
        #expect(value.defaultEngine.name == "搜索引擎")
        #expect(value.enabledEngines.map(\.id) == ["custom"])
        #expect(try SearchEngineConfiguration.decode(value.json()).engines[1].id == "other")
    }

    @Test(arguments: [
        "javascript:alert('{query}')", "ftp://example.com/{query}", "/search?q={query}",
        "https:///{query}", "https://{query}.example.com/", "https://example.com:{query}/",
        "https://user:{query}@example.com/", "https://user:pass@example.com/?q={query}",
        "https://example.com:70000/?q={query}", "https://example.com/?q={unknown}",
        "https://example.com/?q={query}&x={oops}", "https://example.com/?q=query",
        "https://example.com/a b?q={query}", "https://example.com/\\{query}",
        "https://example.com/?q={query}&bad=%zz", "https://exa%mple.com/?q={query}"
    ])
    func invalidTemplatesAreRejectedByValidationAndURLConstruction(_ template: String) {
        #expect(throws: (any Error).self) { try configuration([engine(template)]).validated() }
        #expect(engine(template).searchURL(for: "hello") == nil)
    }

    @Test(arguments: ["", "two words", "1find", "中文", String(repeating: "a", count: 33), "kb", "open", "idea", "gm", "file"])
    func invalidAndReservedKeywordsAreRejected(_ keyword: String) {
        #expect(throws: (any Error).self) { try configuration([engine(keyword: keyword)]).validated() }
    }

    @Test func reservedKeywordsRejectEnabledEnginesAndPermitDisabledDrafts() throws {
        var value = engine(id: "other", keyword: "ops")
        #expect(throws: (any Error).self) { try configuration([engine(), value]).validated(reservedKeywords: ["ops"]) }
        value.isEnabled = false
        #expect(try configuration([engine(), value]).validated(reservedKeywords: ["ops"]).enabledEngines.count == 1)
    }

    @Test func duplicatesInvalidDefaultsAndMissingEnabledEnginesAreRejected() {
        var disabled = engine()
        disabled.isEnabled = false
        let values = [configuration([]), configuration([engine()], defaultID: "missing"),
                      configuration([disabled]), configuration([engine(), engine()]),
                      configuration([engine(), engine(id: "second", keyword: "FIND")])]
        for value in values { #expect(throws: (any Error).self) { try value.validated() } }
        #expect(throws: (any Error).self) { try configuration([engine(id: "")]).validated() }
        #expect(throws: (any Error).self) { try SearchEngineConfiguration(version: 2, defaultEngineID: "custom", engines: [engine()]).validated() }
    }

    @Test func labelsAndEngineCountsAreBounded() throws {
        for name in ["", String(repeating: "中", count: 121), "bad\nname"] {
            var value = engine()
            value.name = name
            #expect(throws: (any Error).self) { try configuration([value]).validated() }
        }
        let hundred = (0..<100).map { engine(id: "id\($0)", keyword: "k\($0)") }
        #expect(try configuration(hundred, defaultID: "id0").validated().engines.count == 100)
        #expect(throws: (any Error).self) { try configuration(hundred + [engine()], defaultID: "id0").validated() }
    }

    @Test func decodingRejectsUnknownMissingAndMistypedFieldsAndOversizeJSON() throws {
        let good = #"{"version":1,"defaultEngineID":"custom","engines":[{"id":"custom","name":"搜索","keyword":"find","urlTemplate":"https://search.example/?q={query}","isEnabled":true}]}"#
        #expect(try SearchEngineConfiguration.decode(good).defaultEngine.id == "custom")
        for bad in [good.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"typo\":true"),
                    good.replacingOccurrences(of: "\"isEnabled\":true", with: "\"isEnabled\":true,\"typo\":true"),
                    good.replacingOccurrences(of: "\"id\":\"custom\",", with: ""),
                    good.replacingOccurrences(of: "\"version\":1,", with: ""),
                    good.replacingOccurrences(of: "\"isEnabled\":true", with: "\"isEnabled\":null"),
                    good.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
                    good + String(repeating: " ", count: 1_048_576)] {
            #expect(throws: (any Error).self) { try SearchEngineConfiguration.decode(bad) }
        }
    }
}
