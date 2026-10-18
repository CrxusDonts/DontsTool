import Foundation

public enum TimestampUnit: String, CaseIterable, Sendable { case automatic = "自动", seconds = "秒", milliseconds = "毫秒" }
public struct TimestampResult: Sendable {
    public let seconds: String
    public let milliseconds: String
    public let date: String
    public var text: String { "秒：\(seconds)\n毫秒：\(milliseconds)\n日期：\(date)" }
}
public enum ToolOperations {
    public static let textByteLimit = 2 * 1024 * 1024
    public static func checkSize(_ input: String) throws {
        guard input.utf8.count <= textByteLimit else { throw ActionError.invalidInput("文本超过 2 MiB 限制") }
        try Task.checkCancellation()
    }
    public static func base64(_ input: String, decode: Bool, urlSafe: Bool = false) throws -> String {
        try checkSize(input)
        if !decode {
            let output = Data(input.utf8).base64EncodedString()
            return urlSafe ? output.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") : output
        }
        var text = input.filter { !$0.isWhitespace }
        if urlSafe { text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") }
        guard text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47 || $0 == 61 }) else {
            throw ActionError.invalidInput("Base64 包含非法字符，请检查编码模式")
        }
        let content = text.prefix(while: { $0 != "=" })
        let padding = text.count - content.count
        guard padding <= 2, text.suffix(padding).allSatisfy({ $0 == "=" }), content.count % 4 != 1,
              padding == 0 || (text.count % 4 == 0 && padding == (4 - content.count % 4) % 4) else {
            throw ActionError.invalidInput("Base64 的长度或末尾填充不正确")
        }
        if padding == 0 { text += String(repeating: "=", count: (4 - text.count % 4) % 4) }
        guard let data = Data(base64Encoded: text) else { throw ActionError.invalidInput("不是有效的 Base64") }
        guard let result = String(data: data, encoding: .utf8) else { throw ActionError.invalidInput("解码结果不是 UTF-8 文本；此工具处理文本内容") }
        return result
    }
    public static func url(_ input: String, decode: Bool, form: Bool = false) throws -> String {
        try checkSize(input)
        if decode { return try TextTransformers.urlDecode(form ? input.replacingOccurrences(of: "+", with: " ") : input) }
        let result = try TextTransformers.urlEncode(input)
        return form ? result.replacingOccurrences(of: "%20", with: "+") : result
    }
    public static func uuids(count: Int, uppercase: Bool, hyphens: Bool) throws -> [String] {
        guard (1...1000).contains(count) else { throw ActionError.invalidInput("数量应为 1–1000 的整数") }
        return try (0..<count).map { _ in
            try Task.checkCancellation()
            var value = UUID().uuidString
            if !uppercase { value = value.lowercased() }
            if !hyphens { value = value.replacingOccurrences(of: "-", with: "") }
            return value
        }
    }
    public static func timestamps(_ input: String, unit: TimestampUnit = .automatic, timeZone: TimeZone = .current, now: Date = Date()) throws -> TimestampResult {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let date: Date
        if text.isEmpty { date = now }
        else if let numeric = Double(text), numeric.isFinite {
            let selected: TimestampUnit
            if unit == .automatic {
                let digits = text.first == "-" || text.first == "+" ? text.dropFirst() : text[...]
                let count = digits.utf8.count
                guard digits.utf8.allSatisfy({ (48...57).contains($0) }), count == 10 || count == 13 else { throw ActionError.invalidInput("请明确选择秒或毫秒；自动识别仅支持 10/13 位时间戳") }
                selected = count == 10 ? .seconds : .milliseconds
            } else { selected = unit }
            let seconds = selected == .milliseconds ? numeric / 1000 : numeric
            guard abs(seconds) <= 253402300799 else { throw ActionError.invalidInput("时间超出支持范围") }
            date = Date(timeIntervalSince1970: seconds)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; formatter.isLenient = false
            var parsed = strictISODate(text)
            if parsed == nil, let candidate = formatter.date(from: text), formatter.string(from: candidate) == text { parsed = candidate }
            guard let parsed else { throw ActionError.invalidInput("日期无效；支持 yyyy-MM-dd HH:mm:ss 或带时区的 ISO 8601") }
            date = parsed
        }
        guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) <= 253402300799 else { throw ActionError.invalidInput("时间超出支持范围") }
        let display = DateFormatter()
        display.locale = Locale(identifier: "en_US_POSIX"); display.timeZone = timeZone
        display.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return TimestampResult(seconds: String(Int64(floor(date.timeIntervalSince1970))), milliseconds: String(Int64((date.timeIntervalSince1970 * 1000).rounded())), date: display.string(from: date))
    }
    private static func strictISODate(_ text: String) -> Date? {
        // ISO8601DateFormatter normalizes impossible dates and accepts trailing text.
        // Validate the complete calendar representation before asking it to apply the offset.
        let pattern = #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(?:Z|[+-]([0-9]{2}):?([0-9]{2}))\z"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
        let values = (1...6).map { Int(source.substring(with: match.range(at: $0)))! }
        let year = values[0], month = values[1], day = values[2]
        guard year > 0, (1...12).contains(month), values[3] < 24, values[4] < 60, values[5] < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        if match.range(at: 7).location != NSNotFound {
            guard Int(source.substring(with: match.range(at: 7)))! < 24,
                  Int(source.substring(with: match.range(at: 8)))! < 60 else { return nil }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return iso.date(from: text)
    }

}
