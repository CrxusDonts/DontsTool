import CryptoKit
import Foundation

public enum HashAlgorithm: String, CaseIterable, Sendable {
    case md5
    case sha1
    case sha256

    public var displayName: String {
        rawValue.uppercased()
    }
}

public struct TimestampConversion: Sendable {
    public let title: String
    public let output: String
    public let subtitle: String

    public init(title: String, output: String, subtitle: String) {
        self.title = title
        self.output = output
        self.subtitle = subtitle
    }
}

public enum TextTransformers {
    public static func formatJSON(_ input: String, pretty: Bool) throws -> String {
        try JSONDocument.parse(input).formatted(pretty: pretty)
    }

    public static func base64Encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    public static func base64Decode(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let string = String(data: data, encoding: .utf8) else {
            throw ActionError.invalidInput("不是有效的 Base64 文本")
        }
        return string
    }

    public static func urlEncode(_ input: String) throws -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = input.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ActionError.invalidInput("URL 编码失败")
        }
        return encoded
    }

    public static func urlDecode(_ input: String) throws -> String {
        guard let decoded = input.removingPercentEncoding else {
            throw ActionError.invalidInput("不是有效的百分号编码")
        }
        return decoded
    }

    public static func transformTimestamp(
        _ input: String,
        now: Date,
        timeZone: TimeZone = .current
    ) throws -> TimestampConversion {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let timestamp = String(Int(now.timeIntervalSince1970))
            return TimestampConversion(
                title: "当前时间",
                output: timestamp,
                subtitle: displayFormatter(timeZone: timeZone).string(from: now)
            )
        }

        if trimmed.allSatisfy(\.isNumber) {
            let seconds: TimeInterval
            if trimmed.count == 10 {
                seconds = TimeInterval(trimmed) ?? 0
            } else if trimmed.count == 13 {
                seconds = (TimeInterval(trimmed) ?? 0) / 1000
            } else {
                throw ActionError.invalidInput("时间戳应为 10 位秒或 13 位毫秒")
            }
            let date = Date(timeIntervalSince1970: seconds)
            let display = displayFormatter(timeZone: timeZone).string(from: date)
            return TimestampConversion(title: trimmed, output: display, subtitle: "时间戳转日期")
        }

        if let date = parseDate(trimmed, timeZone: timeZone) {
            let timestamp = String(Int(date.timeIntervalSince1970))
            return TimestampConversion(title: trimmed, output: timestamp, subtitle: "日期转时间戳")
        }

        throw ActionError.invalidInput("无法识别的时间；支持 10/13 位时间戳或 yyyy-MM-dd HH:mm:ss")
    }

    public static func hash(_ input: String, algorithm: HashAlgorithm) -> String {
        let data = Data(input.utf8)
        let digest: [UInt8]
        switch algorithm {
        case .md5:
            digest = Array(Insecure.MD5.hash(data: data))
        case .sha1:
            digest = Array(Insecure.SHA1.hash(data: data))
        case .sha256:
            digest = Array(SHA256.hash(data: data))
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func displayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    private static func parseDate(_ input: String, timeZone: TimeZone) -> Date? {
        let formatter = displayFormatter(timeZone: timeZone)
        if let date = formatter.date(from: input) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: input) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: input)
    }
}
