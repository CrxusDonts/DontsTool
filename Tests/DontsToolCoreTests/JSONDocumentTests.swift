import Foundation
import Testing
@testable import DontsToolCore

@Suite("JSON 工作区")
struct JSONDocumentTests {
    @Test func preservesNumbersAndOrder() throws {
        let doc = try JSONDocument.parse(#"{"z":9007199254740993,"a":1.2300e+40}"#)
        #expect(try doc.formatted(pretty: false) == #"{"z":9007199254740993,"a":1.2300e+40}"#)
        #expect(try doc.formatted(pretty: true).contains("\n  \"z\""))
    }
    @Test(arguments: ["null", "true", "9007199254740993", #""中文""#, "[]"])
    func rootValues(_ input: String) throws {
        #expect(try JSONDocument.parse(input).formatted(pretty: false) == input)
    }
    @Test func duplicateAndLocation() throws {
        do {
            _ = try JSONDocument.parse("{\n  \"a\": 1,\n  \"a\": 2\n}")
            Issue.record("重复键未被拒绝")
        } catch let error as JSONIssue {
            #expect(error.line == 3)
            #expect(error.column == 3)
        }
        #expect(throws: (any Error).self) { try JSONDocument.parse(#"{"a":01}"#) }
        #expect(throws: (any Error).self) { try JSONDocument.parse(#""\uD800""#) }
    }
    @Test func escapesExactlyOneLayer() throws {
        let input = "中文\n\"a\"\\n"
        let escaped = JSONDocument.escape(input)
        #expect(try JSONDocument.unescape(escaped) == input)
        #expect(try JSONDocument.unescape(#"{\"a\":1}"#, bare: true) == #"{"a":1}"#)
        #expect(try JSONDocument.unescape(#""\\n""#) == #"\n"#)
    }
    @Test func structuralComparison() throws {
        let same = try JSONDiff.compare(#"{"b":true,"a":1.0}"#, #"{"a":1e0,"b":true}"#)
        #expect(same.total == 0)
        let changed = try JSONDiff.compare(#"{"a/b":{"~":9007199254740993},"x":[1,2]}"#, #"{"a/b":{"~":9007199254740992},"x":[2,1],"n":null}"#)
        #expect(changed.total == 4)
        #expect(changed.added == 1)
        #expect(changed.differences.first?.path == "/a~1b/~0")
        #expect(changed.differences.first?.leftRange != nil)
        #expect(try JSONDiff.compare("true", "1").total == 1)
    }
    @Test func hugeExponentsCompareWithoutFloatingPoint() throws {
        #expect(try JSONDiff.compare("10e99999999999999999999", "1e100000000000000000000").total == 0)
        #expect(try JSONDiff.compare("-0e99999999999999999999", "0").total == 0)
    }
    @Test func limitsAreEnforced() throws {
        #expect(throws: (any Error).self) { try JSONDocument.parse(String(repeating: "[", count: 257) + String(repeating: "]", count: 257)) }
        #expect(throws: (any Error).self) { try JSONDocument.parse(String(repeating: " ", count: 2 * 1024 * 1024 + 1)) }
    }
    @Test func maximumDepthCanParseRenderAndCompare() throws {
        let input = String(repeating: "[", count: 256) + "0" + String(repeating: "]", count: 256)
        let document = try JSONDocument.parse(input)
        #expect(try document.formatted(pretty: false) == input)
        #expect(try JSONDocument.parse(document.formatted(pretty: true)).formatted(pretty: false) == input)
        #expect(try JSONDiff.compare(input, input).total == 0)
    }
    @Test func unicodeKeysAndValuesUseExactCodePoints() throws {
        let input = #"{"é":1,"e\u0301":2}"#
        #expect(try JSONDocument.parse(input).formatted(pretty: false).contains("2"))
        #expect(try JSONDiff.compare(#""é""#, #""e\u0301""#).total == 1)
        #expect(try JSONDiff.compare(#"{"é":1}"#, #"{"e\u0301":1}"#).total == 2)
        #expect(throws: JSONIssue.self) { try JSONDocument.parse(#"{"a":1,"\u0061":2}"#) }
    }
    @Test func diffRangesUseUTF16() throws {
        let source = #"{"😀":0,"value":"旧😀"}"#
        let comparison = try JSONDiff.compare(source, #"{"😀":0,"value":"新😀"}"#)
        let range = try #require(comparison.differences.first?.leftRange)
        #expect((source as NSString).substring(with: range) == #""旧😀""#)
    }
    @Test func cancelledFormattingStopsInsteadOfProducingOutput() async throws {
        let document = try JSONDocument.parse("[" + Array(repeating: "0", count: 100_000).joined(separator: ",") + "]")
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try document.formatted(pretty: true); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(cancelled)
    }
    @Test func diffPreservesCancellation() async {
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try JSONDiff.compare("[]", "[]"); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(cancelled)
    }
    @Test(arguments: [("1e-99999999999999999999", "10e-100000000000000000000"),
                      ("1000000000000000000000", "1e21"), ("-12.300", "-123e-1"), ("0.00100", "1e-3")])
    func exactEquivalentNumbers(_ pair: (String, String)) throws {
        #expect(try JSONDiff.compare(pair.0, pair.1).total == 0)
    }
    @Test func diffCountsBeyondDisplayLimit() throws {
        let left = "[" + Array(repeating: "0", count: 1001).joined(separator: ",") + "]"
        let right = "[" + Array(repeating: "1", count: 1001).joined(separator: ",") + "]"
        let result = try JSONDiff.compare(left, right)
        #expect(result.modified == 1001)
        #expect(result.differences.count == 1000)
    }

    @Test(arguments: ["\r", "\r\n", "\n"])
    func duplicateKeysLocateAllJSONLineEndings(_ newline: String) {
        let input = "{" + newline + #""a":1,"# + newline + #""a":2}"#
        do { _ = try JSONDocument.parse(input); Issue.record("重复键未被拒绝") }
        catch let issue as JSONIssue {
            #expect(issue.line == 3)
            #expect(issue.column == 1)
            #expect((input as NSString).substring(with: issue.range) == #"""#)
        } catch { Issue.record(error) }
    }
    @Test func maximumObjectDepthCanParseRenderAndCompare() throws {
        let input = String(repeating: #"{"a":"#, count: 256) + "0" + String(repeating: "}", count: 256)
        let document = try JSONDocument.parse(input)
        #expect(try document.formatted(pretty: false) == input)
        #expect(try JSONDiff.compare(input, input).total == 0)
        #expect(try JSONDiff.compare(input, "null").differences.first?.left == input)
    }

    @Test func formattingRejectsExcessiveIndentationExpansion() throws {
        // Under 41 KiB of input expands beyond 9 MiB at the supported depth.
        let input = String(repeating: "[", count: 256)
            + Array(repeating: "0", count: 20_000).joined(separator: ",")
            + String(repeating: "]", count: 256)
        let document = try JSONDocument.parse(input)
        #expect(try document.formatted(pretty: false) == input)
        do {
            _ = try document.formatted(pretty: true)
            Issue.record("格式化未拒绝过大的输出")
        } catch let error as ActionError {
            #expect(error.localizedDescription.contains("输出"))
            #expect(error.localizedDescription.contains("压缩"))
        }
    }

}
