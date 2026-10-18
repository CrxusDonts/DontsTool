import Foundation
import Testing
@testable import DontsToolCore

@Suite("工具操作")
struct ToolOperationsTests {
    @Test func base64Variants() throws {
        #expect(try ToolOperations.base64("5Lit\n5paH", decode: true) == "中文")
        #expect(try ToolOperations.base64("aGk", decode: true) == "hi")
        #expect(try ToolOperations.base64("", decode: true) == "")
        #expect(throws: (any Error).self) { try ToolOperations.base64("***", decode: true) }
        #expect(throws: (any Error).self) { try ToolOperations.base64("/w==", decode: true) }
        #expect(try ToolOperations.base64("8J-YgA", decode: true, urlSafe: true) == "😀")
        #expect(throws: (any Error).self) { try ToolOperations.base64("ab=c", decode: true) }
    }
    @Test func URLModes() throws {
        #expect(try ToolOperations.url("a+b c", decode: false) == "a%2Bb%20c")
        #expect(try ToolOperations.url("a+b", decode: true) == "a+b")
        #expect(try ToolOperations.url("a+b", decode: true, form: true) == "a b")
        #expect(try ToolOperations.url("a+b c", decode: false, form: true) == "a%2Bb+c")
        #expect(throws: (any Error).self) { try ToolOperations.url("%FF", decode: true) }
        #expect(throws: (any Error).self) { try ToolOperations.url("%G1", decode: true) }
    }
    @Test func timestampStrictUnits() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(try ToolOperations.timestamps("-1", unit: .seconds, timeZone: utc).seconds == "-1")
        #expect(try ToolOperations.timestamps("1700000000123", timeZone: utc).milliseconds == "1700000000123")
        #expect(try ToolOperations.timestamps("2023-11-14T23:13:20+01:00", timeZone: utc).seconds == "1700000000")
        #expect(throws: (any Error).self) { try ToolOperations.timestamps("123", timeZone: utc) }
        #expect(throws: (any Error).self) { try ToolOperations.timestamps("2023-02-30 12:00:00", timeZone: utc) }
    }
    @Test func UUIDBatchOptions() throws {
        let values = try ToolOperations.uuids(count: 8, uppercase: false, hyphens: true)
        #expect(values.count == 8)
        #expect(Set(values).count == 8)
        #expect(values.allSatisfy { $0.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil })
        #expect(try ToolOperations.uuids(count: 1, uppercase: true, hyphens: false)[0].count == 32)
        #expect(throws: (any Error).self) { try ToolOperations.uuids(count: 1001, uppercase: false, hyphens: true) }
        #expect(throws: (any Error).self) { try ToolOperations.uuids(count: 0, uppercase: false, hyphens: true) }
    }
    @Test(arguments: ["2023-02-30T12:00:00Z", "2023-02-29T12:00:00+01:00", "2023-11-14T24:00:00Z", "2023-11-14T22:13:20Ztrailing", "2023-02-30T12:00:00.123Z"])
    func rejectsImpossibleOrPartialISODates(_ input: String) {
        #expect(throws: (any Error).self) { try ToolOperations.timestamps(input, timeZone: TimeZone(secondsFromGMT: 0)!) }
    }
    @Test func automaticTimestampRequiresIntegerDigits() {
        #expect(throws: (any Error).self) { try ToolOperations.timestamps("1e000000000") }
    }
    @Test(arguments: ["=", "====", "YQ=", "YQ===", "YWJj=", "Y=Q=", "a"])
    func rejectsMalformedBase64Padding(_ input: String) {
        #expect(throws: (any Error).self) { try ToolOperations.base64(input, decode: true) }
    }
    @Test func timestampBoundariesAndLeapYear() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(try ToolOperations.timestamps("2024-02-29T12:00:00.125+01:00", timeZone: utc).milliseconds == "1709204400125")
        #expect(try ToolOperations.timestamps("253402300799", unit: .seconds, timeZone: utc).date.hasPrefix("9999-12-31"))
        #expect(throws: (any Error).self) { try ToolOperations.timestamps("253402300800", unit: .seconds) }
        #expect(throws: (any Error).self) { try ToolOperations.timestamps("inf", unit: .seconds) }
        #expect(throws: (any Error).self) { try ToolOperations.timestamps("NaN", unit: .seconds) }
    }

}
