import Foundation
import Testing
@testable import DontsToolCore

@Suite("TextTransformers")
struct TextTransformersTests {
    @Test func jsonPrettyAndMinify() throws {
        let pretty = try TextTransformers.formatJSON(#"{"b":2,"a":1}"#, pretty: true)
        #expect(pretty.contains("\n"))
        #expect(pretty.contains("\"a\""))
        let minified = try TextTransformers.formatJSON(#"{"b":2,"a":1}"#, pretty: false)
        #expect(!minified.contains("\n"))
    }

    @Test func invalidJSONThrows() {
        #expect(throws: (any Error).self) {
            try TextTransformers.formatJSON("not json", pretty: true)
        }
    }

    @Test func base64RoundTrip() throws {
        let encoded = TextTransformers.base64Encode("hello")
        #expect(encoded == "aGVsbG8=")
        #expect(try TextTransformers.base64Decode(encoded) == "hello")
    }

    @Test func invalidBase64Throws() {
        #expect(throws: (any Error).self) {
            try TextTransformers.base64Decode("***")
        }
    }

    @Test func urlEncodeUsesRFC3986() throws {
        #expect(try TextTransformers.urlEncode("a b") == "a%20b")
        #expect(try TextTransformers.urlDecode("a%20b") == "a b")
        #expect(try TextTransformers.urlEncode("中") == "%E4%B8%AD")
    }

    @Test func timestampSecondsAndMilliseconds() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let seconds = try TextTransformers.transformTimestamp("1700000000", now: Date(), timeZone: utc)
        #expect(seconds.output == "2023-11-14 22:13:20")
        let milliseconds = try TextTransformers.transformTimestamp("1700000000000", now: Date(), timeZone: utc)
        #expect(milliseconds.output == "2023-11-14 22:13:20")
    }

    @Test func dateStringConvertsToTimestamp() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let result = try TextTransformers.transformTimestamp("2023-11-14 22:13:20", now: Date(), timeZone: utc)
        #expect(result.output == "1700000000")
    }

    @Test func invalidTimestampThrows() {
        #expect(throws: (any Error).self) {
            try TextTransformers.transformTimestamp("123", now: Date(), timeZone: TimeZone(secondsFromGMT: 0)!)
        }
    }

    @Test func hashKnownVectors() {
        #expect(TextTransformers.hash("hello", algorithm: .md5) == "5d41402abc4b2a76b9719d911017c592")
        #expect(TextTransformers.hash("hello", algorithm: .sha1) == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
        #expect(TextTransformers.hash("hello", algorithm: .sha256) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
