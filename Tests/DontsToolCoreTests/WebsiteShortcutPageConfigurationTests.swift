import Foundation
import Testing
@testable import DontsToolCore

@Suite("Website page configuration")
struct WebsiteShortcutPageConfigurationTests {
    private func configuration(item: String, version: Int = 3) -> String {
        """
        {"version":\(version),"groups":[{"keyword":"ops","name":"业务系统","items":[\(item)]}]}
        """
    }

    private let environmentItem = """
    {"key":"avatar","name":"头像管理","environments":[
      {"key":"prod","url":"https://prod.example/base?old=1#old"},
      {"key":"test","url":"http://test.example:8080/base"}
    ],"pages":[{"key":"management","name":"管理","path":"/admin?tab=a%2Fb#section%20one","aliases":["后台"]}]}
    """

    @Test func versionThreeAcceptsEnvironmentPagesAndRoundTrips() throws {
        let value = try WebsiteShortcutConfiguration.decode(configuration(item: environmentItem))
        #expect(value.version == 3)
        #expect(try WebsiteShortcutConfiguration.decode(value.json()) == value)
        #expect(try value.json().contains("management"))
    }

    @Test func legacyShapesRemainWithoutPagesAfterRoundTrip() throws {
        for version in [1, 2] {
            let value = try WebsiteShortcutConfiguration.decode(configuration(
                item: #"{"key":"avatar","name":"头像管理","url":"https://example.com"}"#, version: version))
            #expect(value.version == version)
            #expect(try !value.json().contains("pages"))
            #expect(try WebsiteShortcutConfiguration.decode(value.json()) == value)
        }
    }

    @Test func addressCountIncludesHomeAndEveryPageEnvironment() throws {
        let value = try WebsiteShortcutConfiguration.decode(configuration(item: environmentItem))
        #expect(value.itemCount == 1)
        #expect(value.addressCount == 4)
    }

    @Test func allEnvironmentOverridesAllowAnEmptyPath() throws {
        let item = #"{"key":"avatar","name":"头像管理","environments":[{"key":"prod","url":"https://prod.example"},{"key":"test","url":"https://test.example"}],"pages":[{"key":"management","name":"管理","urls":{"PROD":"https://special.example/admin","test":"https://test-special.example"}}]}"#
        let value = try WebsiteShortcutConfiguration.decode(configuration(item: item))
        #expect(try WebsiteShortcutConfiguration.decode(value.json()) == value)
    }

    @Test func singleURLSystemsSupportPages() throws {
        let value = try WebsiteShortcutConfiguration.decode(configuration(item: #"{"key":"avatar","name":"头像管理","url":"https://example.com/base","pages":[{"key":"management","name":"管理","path":"/admin"}]}"#))
        #expect(value.addressCount == 2)
    }

    @Test func singleURLSystemsRejectEnvironmentOverrides() {
        #expect(throws: (any Error).self) {
            try WebsiteShortcutConfiguration.decode(configuration(item: #"{"key":"avatar","name":"头像管理","url":"https://example.com/base","pages":[{"key":"management","name":"管理","path":"/admin","urls":{"prod":"https://prod.example"}}]}"#))
        }
    }

    @Test func resolvedPageURLsPreserveEncodedQueryAndFragmentAndUseTheOrigin() throws {
        let value = try WebsiteShortcutConfiguration.decode(configuration(item: environmentItem))
        let item = try #require(value.groups.first?.items.first)
        let page = try #require(item.pages.first)
        #expect(value.pageCount == 1)
        #expect(try page.resolvedURL(baseURL: item.environments[0].url, environmentKey: "prod").absoluteString == "https://prod.example/admin?tab=a%2Fb#section%20one")
        #expect(try page.resolvedURL(baseURL: item.environments[1].url, environmentKey: "test").absoluteString == "http://test.example:8080/admin?tab=a%2Fb#section%20one")
    }

    @Test func fullURLFallbackAndEnvironmentOverrideRemainExact() throws {
        let page = WebsiteShortcutPage(key: "special", name: "特殊页面", path: "https://shared.example/a%2Fb?q=%2F#part%20one", urls: ["prod": "https://special.example/a%2Fb?q=%25#part%20two"])
        #expect(try page.resolvedURL(baseURL: "https://base.example/old", environmentKey: "prod").absoluteString == "https://special.example/a%2Fb?q=%25#part%20two")
        #expect(try page.resolvedURL(baseURL: "https://base.example/old", environmentKey: "test").absoluteString == "https://shared.example/a%2Fb?q=%2F#part%20one")
    }

    @Test func rootPathResolvesForSingleURLAndRemovesBaseQueryAndFragment() throws {
        let page = WebsiteShortcutPage(key: "root", name: "站点根目录", path: "/?value=%2F#anchor")
        #expect(try page.resolvedURL(baseURL: "https://example.com:8443/old?before=1#old").absoluteString == "https://example.com:8443/?value=%2F#anchor")
    }

    @Test func manualValidationAndJSONRetainInvalidPages() throws {
        let value = WebsiteShortcutConfiguration(version: 2, groups: [.init(keyword: "ops", name: "业务系统", items: [
            .init(key: "avatar", name: "头像管理", url: "https://example.com", pages: [.init(key: "admin", name: "管理", path: "/admin")])
        ])])
        #expect(try value.json().contains("pages"))
        #expect(throws: (any Error).self) { try value.validated() }
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(value.json()) }
    }

    @Test func defaultVersionIsThreeAndJSONVersionRemainsRequired() {
        #expect(WebsiteShortcutConfiguration(groups: []).version == 3)
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(#"{"groups":[]}"#) }
    }

    @Test func pageKeysAndAliasesAreUniqueAcrossTheSystem() {
        let item = #"{"key":"avatar","name":"头像管理","url":"https://example.com","pages":[{"key":"admin","name":"管理","path":"/admin","aliases":["user  settings"]},{"key":"users","name":"用户","path":"/users","aliases":["USER settings"]}]}"#
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(configuration(item: item)) }
    }

    @Test func pageAndResolvedAddressLimitsIncludeEveryEnvironment() throws {
        let pages = (0..<100).map { WebsiteShortcutPage(key: "p\($0)", name: "页面\($0)", path: "/p\($0)") }
        let environments = (0..<25).map { WebsiteShortcutEnvironment(key: "e\($0)", url: "https://e\($0).example.com") }
        let item = WebsiteShortcut(key: "avatar", name: "头像管理", environments: environments, pages: pages)
        let twoItems = WebsiteShortcutConfiguration(groups: [.init(keyword: "ops", name: "业务系统", items: [item, .init(key: "other", name: "其他系统", environments: environments, pages: pages)])])
        #expect(twoItems.addressCount == 5050)
        let boundaryItems = [
            WebsiteShortcut(key: "avatar", name: "头像管理", environments: environments, pages: Array(pages.dropLast())),
            WebsiteShortcut(key: "other", name: "其他系统", environments: environments, pages: Array(pages.dropLast()))
        ]
        #expect(try WebsiteShortcutConfiguration(groups: [.init(keyword: "ops", name: "业务系统", items: boundaryItems)]).validated().addressCount == 5000)
        #expect(throws: (any Error).self) { try twoItems.validated() }
        var tooMany = item
        tooMany.pages.append(.init(key: "extra", name: "额外页面", path: "/extra"))
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration(groups: [.init(keyword: "ops", name: "业务系统", items: [tooMany])]).validated() }
        #expect(try WebsiteShortcutConfiguration(groups: [.init(keyword: "ops", name: "业务系统", items: [item])]).validated().pageCount == 100)
    }

    @Test func pageLabelsAndAliasCountsHaveLimits() {
        let invalidPages: [WebsiteShortcutPage] = [
            .init(key: String(repeating: "p", count: 65), name: "页面", path: "/page"),
            .init(key: "two words", name: "页面", path: "/page"),
            .init(key: "p", name: "", path: "/page"),
            .init(key: "p", name: String(repeating: "页", count: 121), path: "/page"),
            .init(key: "p", name: "页面", path: "/page", aliases: (0..<31).map { "alias\($0)" })
        ]
        for page in invalidPages {
            let value = WebsiteShortcutConfiguration(groups: [.init(keyword: "ops", name: "业务系统", items: [
                .init(key: "avatar", name: "头像管理", url: "https://example.com", pages: [page])
            ])])
            #expect(throws: (any Error).self) { try value.validated() }
        }
    }

    @Test(arguments: [1, 2]) func explicitPagesRequireVersionThree(_ version: Int) {
        #expect(throws: (any Error).self) {
            try WebsiteShortcutConfiguration.decode(configuration(item: #"{"key":"avatar","name":"头像管理","url":"https://example.com","pages":[]}"#, version: version))
        }
    }

    @Test(arguments: [
        #"{"key":"management","name":"管理","path":"/admin","unknown":true}"#,
        #"{"key":"management","name":"管理","path":null}"#,
        #"{"key":"management","name":"管理","path":"/admin","aliases":null}"#,
        #"{"key":"management","name":"管理","path":"/admin","urls":null}"#,
        #"{"key":"management","name":"管理","path":"//other.example/admin"}"#,
        #"{"key":"management","name":"管理","path":"admin"}"#,
        #"{"key":"management","name":"管理","path":"/admin path"}"#,
        #"{"key":"management","name":"管理","path":"/admin\\path"}"#,
        #"{"key":"management","name":"管理","path":"javascript:alert(1)"}"#,
        #"{"key":"management","name":"管理","path":"https://user:pass@example.com/admin"}"#,
        #"{"key":"management","name":"管理","path":"https://example.com:70000/admin"}"#,
        #"{"key":"management","name":"管理","path":"bad","urls":{"prod":"https://prod.example","test":"https://test.example"}}"#,
        #"{"key":"management","name":"管理","path":"/admin","urls":{"PROD":"https://prod.example","prod":"https://other.example"}}"#,
        #"{"key":"management","name":"管理","path":"/admin","aliases":["a  b","Ａ b"]}"#,
        #"{"key":"home","name":"管理","path":"/admin"}"#,
        #"{"key":"management","name":"管理","path":"/admin","aliases":["首页"]}"#,
        #"{"key":"management","name":"管理","path":"/admin","urls":{"staging":"https://other.example"}}"#,
        #"{"key":"management","name":"管理","urls":{"prod":"https://other.example"}}"#
    ])
    func invalidPageDefinitionsAreRejected(_ page: String) {
        let item = """
        {"key":"avatar","name":"头像管理","environments":[{"key":"prod","url":"https://prod.example"},{"key":"test","url":"https://test.example"}],"pages":[\(page)]}
        """
        #expect(throws: (any Error).self) { try WebsiteShortcutConfiguration.decode(configuration(item: item)) }
    }
}
