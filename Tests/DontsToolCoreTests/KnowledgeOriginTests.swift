import Foundation
import Testing
@testable import DontsToolCore

@Suite("知识库来源边界")
struct KnowledgeOriginTests {
    @Test func normalizesOriginAndAllowsOnlySecureOrLoopbackOrigins() throws {
        #expect(try KnowledgeOrigin(" HTTPS://KB.Example.com:443/ ").baseURL.absoluteString == "https://kb.example.com")
        #expect(try KnowledgeOrigin("http://localhost:5173").baseURL.absoluteString == "http://localhost:5173")
        #expect(try KnowledgeOrigin("http://127.0.0.1:5173/").baseURL.absoluteString == "http://127.0.0.1:5173")
        #expect(try KnowledgeOrigin("http://[::1]:5173").baseURL.absoluteString == "http://[::1]:5173")
        for raw in ["", "kb.example.com", "http://kb.example.com", "http://localhost.evil.test", "https://user:pass@kb.example.com", "https://kb.example.com/path", "https://kb.example.com/?token=x", "https://kb.example.com/#token", "javascript:alert(1)", "https://kb.example.com:0", "https://kb.example.com:65536"] {
            #expect(throws: (any Error).self) { try KnowledgeOrigin(raw) }
        }
    }

    @Test func buildsEncodedDocumentAndSearchRoutesWithoutCaptureTextInURL() throws {
        let origin = try KnowledgeOrigin("https://kb.example.com")
        let document = origin.url(for: .init(surface: .editor, documentID: "doc/a & 中文", blockID: "block#2"))
        let components = try #require(URLComponents(url: document, resolvingAgainstBaseURL: false))
        #expect(components.path == "/tool")
        #expect(components.queryItems == [URLQueryItem(name: "mode", value: "editor"), URLQueryItem(name: "documentId", value: "doc/a & 中文"), URLQueryItem(name: "blockId", value: "block#2")])
        let search = origin.url(for: .init(surface: .search, query: "hello + 世界 & more"))
        #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.last == URLQueryItem(name: "q", value: "hello + 世界 & more"))
        let capture = origin.url(for: .init(surface: .capture, query: "private capture text"))
        #expect(capture.absoluteString == "https://kb.example.com/tool?mode=capture")
    }

    @Test func matchesExactOriginRatherThanHostPrefixOrCredentials() throws {
        let origin = try KnowledgeOrigin("https://kb.example.com")
        #expect(origin.contains(URL(string: "https://kb.example.com:443/tool?q=x")!))
        #expect(!origin.contains(URL(string: "https://kb.example.com.evil.test/tool")!))
        #expect(!origin.contains(URL(string: "https://kb.example.com:8443/tool")!))
        #expect(!origin.contains(URL(string: "http://kb.example.com/tool")!))
        #expect(!origin.contains(URL(string: "https://user@kb.example.com/tool")!))
    }
}
