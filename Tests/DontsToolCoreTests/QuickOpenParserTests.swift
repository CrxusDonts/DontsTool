import Foundation
import Testing
@testable import DontsToolCore

@Suite("QuickOpenParser")
struct QuickOpenParserTests {
    private let noFiles: (String) -> Bool = { _ in false }
    private let allFiles: (String) -> Bool = { _ in true }

    @Test func parsesWebURL() {
        let target = QuickOpenParser.parse("https://example.com/path?q=swift", fileExists: noFiles)
        guard case .url(let url) = target else {
            Issue.record("应为网址")
            return
        }
        #expect(url.absoluteString == "https://example.com/path?q=swift")
    }

    @Test func addsHTTPSForBareWWW() {
        let target = QuickOpenParser.parse("www.example.com", fileExists: noFiles)
        guard case .url(let url) = target else {
            Issue.record("应为网址")
            return
        }
        #expect(url.absoluteString == "https://www.example.com")
    }

    @Test func rejectsOrdinaryText() {
        #expect(QuickOpenParser.parse("not a url", fileExists: noFiles) == nil)
        #expect(QuickOpenParser.parse("Safari", fileExists: allFiles) == nil)
        #expect(QuickOpenParser.parse("open", fileExists: allFiles) == nil)
    }

    @Test func expandsExistingHomePath() {
        let target = QuickOpenParser.parse("~/Desktop", fileExists: allFiles)
        guard case .file(let url) = target else {
            Issue.record("应为文件路径")
            return
        }
        #expect(url.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path)
    }

    @Test func requiresAbsoluteFilePathToExist() {
        #expect(QuickOpenParser.parse("/tmp/report.pdf", fileExists: noFiles) == nil)
        let target = QuickOpenParser.parse("/tmp/report.pdf", fileExists: allFiles)
        guard case .file(let url) = target else {
            Issue.record("应为文件路径")
            return
        }
        #expect(url.path == "/tmp/report.pdf")
    }

    @Test func parsesFileURL() {
        let target = QuickOpenParser.parse("file:///tmp/report.pdf", fileExists: allFiles)
        guard case .file(let url) = target else {
            Issue.record("应为文件路径")
            return
        }
        #expect(url.path == "/tmp/report.pdf")
    }
}
