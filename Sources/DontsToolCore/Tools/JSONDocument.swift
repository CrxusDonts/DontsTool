import Foundation

public struct JSONIssue: LocalizedError, Sendable {
    public let message: String
    public let line: Int
    public let column: Int
    public let range: NSRange
    public var errorDescription: String? { "\(message)（第 \(line) 行，第 \(column) 列）" }
}

public struct JSONMember: Sendable {
    public let key: String
    public let value: JSONNode
}

public struct JSONNode: Sendable {
    public enum Value: Sendable {
        case object([JSONMember]), array([JSONNode]), string(String), number(String), bool(Bool), null
    }
    public let value: Value
    public let range: NSRange

    public func rendered(pretty: Bool, depth: Int = 0) throws -> String {
        var output = ""
        var byteCount = 0
        let byteLimit = 8 * 1024 * 1024
        func append(_ fragment: String) throws {
            let count = fragment.utf8.count
            guard count <= byteLimit - byteCount else {
                throw ActionError.invalidInput("JSON 格式化输出超过 8 MiB 限制，请减少输入或使用压缩模式")
            }
            output += fragment
            byteCount += count
        }
        var steps: [JSONRenderStep] = [.node(self, depth)]
        while let step = steps.popLast() {
            try Task.checkCancellation()
            switch step {
            case .node(let node, let level):
                switch node.value {
                case .object(let members):
                    try append("{")
                    steps.append(.object(members, 0, level))
                case .array(let items):
                    try append("[")
                    steps.append(.array(items, 0, level))
                case .string(let string): try append(JSONDocument.escape(string))
                case .number(let raw): try append(raw)
                case .bool(let bool): try append(bool ? "true" : "false")
                case .null: try append("null")
                }
            case .object(let members, let index, let level):
                if index == members.count {
                    if pretty && !members.isEmpty { try append("\n" + String(repeating: "  ", count: level)) }
                    try append("}")
                } else {
                    if index > 0 { try append(",") }
                    if pretty { try append("\n" + String(repeating: "  ", count: level + 1)) }
                    try append(JSONDocument.escape(members[index].key) + (pretty ? ": " : ":"))
                    steps.append(.object(members, index + 1, level))
                    steps.append(.node(members[index].value, level + 1))
                }
            case .array(let items, let index, let level):
                if index == items.count {
                    if pretty && !items.isEmpty { try append("\n" + String(repeating: "  ", count: level)) }
                    try append("]")
                } else {
                    if index > 0 { try append(",") }
                    if pretty { try append("\n" + String(repeating: "  ", count: level + 1)) }
                    steps.append(.array(items, index + 1, level))
                    steps.append(.node(items[index], level + 1))
                }
            }
        }
        try Task.checkCancellation()
        return output
    }

}

private enum JSONRenderStep {
    case node(JSONNode, Int)
    case object([JSONMember], Int, Int)
    case array([JSONNode], Int, Int)
}

public struct JSONDocument: Sendable {
    public let root: JSONNode
    public static let byteLimit = 2 * 1024 * 1024

    public static func parse(_ text: String) throws -> JSONDocument {
        guard text.utf8.count <= byteLimit else {
            throw JSONIssue(message: "JSON 超过 2 MiB 限制", line: 1, column: 1, range: NSRange(location: 0, length: 0))
        }
        let parser = JSONParser(text)
        let root = try parser.parse()
        return JSONDocument(root: root)
    }

    public func formatted(pretty: Bool) throws -> String { try root.rendered(pretty: pretty) }

    public static func escape(_ text: String) -> String {
        // JSONEncoder handles surrogate pairs and control characters without changing Unicode text.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(text), as: UTF8.self)
    }

    public static func unescape(_ text: String, bare: Bool = false) throws -> String {
        let source = bare ? "\"" + text + "\"" : text
        let document = try parse(source)
        guard case .string(let string) = document.root.value else {
            throw ActionError.invalidInput("去转义需要 JSON 字符串，请检查外层引号或选择无外层引号模式")
        }
        return string
    }
}

private final class JSONParser {
    let source: NSString
    let chars: [UInt16]
    var offset = 0
    init(_ text: String) { source = text as NSString; chars = Array(text.utf16) }
    var current: UInt16? { offset < chars.count ? chars[offset] : nil }
    func whitespace() throws {
        while let c = current, c == 32 || c == 9 || c == 10 || c == 13 {
            offset += 1
            if offset % 1024 == 0 { try Task.checkCancellation() }
        }
    }
    func issue(_ message: String, at location: Int? = nil) -> JSONIssue {
        let position = min(location ?? offset, chars.count)
        var line = 1, column = 1
        for index in 0..<position {
            if chars[index] == 13 {
                line += 1; column = 1
            } else if chars[index] == 10 {
                if index == 0 || chars[index - 1] != 13 { line += 1 }
                column = 1
            } else { column += 1 }
        }
        return JSONIssue(message: message, line: line, column: column,
                         range: NSRange(location: position, length: position < chars.count ? 1 : 0))
    }
    func parse() throws -> JSONNode {
        var frames: [JSONParseFrame] = []
        var completed: JSONNode?
        while true {
            try Task.checkCancellation()
            if completed == nil {
                try whitespace()
                let start = offset
                if current == 123 || current == 91 {
                    guard frames.count < 256 else { throw issue("JSON 嵌套超过 256 层") }
                    let object = current == 123
                    offset += 1
                    try whitespace()
                    let closing: UInt16 = object ? 125 : 93
                    if current == closing {
                        offset += 1
                        completed = JSONNode(value: object ? .object([]) : .array([]), range: NSRange(location: start, length: offset - start))
                    } else {
                        var frame = JSONParseFrame(object: object, start: start)
                        if object { frame.key = try objectKey(keys: &frame.keys) }
                        frames.append(frame)
                        continue
                    }
                } else {
                    completed = try scalar()
                }
            }
            let node = completed!
            guard var frame = frames.popLast() else {
                try whitespace()
                guard current == nil else { throw issue("JSON 值之后还有多余内容") }
                return node
            }
            if frame.object { frame.members.append(JSONMember(key: frame.key!, value: node)) }
            else { frame.nodes.append(node) }
            completed = nil
            try whitespace()
            let closing: UInt16 = frame.object ? 125 : 93
            if current == closing {
                offset += 1
                completed = JSONNode(value: frame.object ? .object(frame.members) : .array(frame.nodes),
                                     range: NSRange(location: frame.start, length: offset - frame.start))
                continue
            }
            guard current == 44 else { throw issue(frame.object ? "对象缺少结束的 }" : "数组缺少结束的 ]") }
            offset += 1
            try whitespace()
            if frame.object { frame.key = try objectKey(keys: &frame.keys) }
            frames.append(frame)
        }
    }
    func objectKey(keys: inout Set<Data>) throws -> String {
        let keyStart = offset
        let key = try string()
        guard keys.insert(Data(key.utf8)).inserted else { throw issue("重复的对象键：\(key)", at: keyStart) }
        try whitespace()
        guard current == 58 else { throw issue("对象键后需要冒号") }
        offset += 1
        return key
    }
    func scalar() throws -> JSONNode {
        let start = offset
        let value: JSONNode.Value
        switch current {
        case 34: value = .string(try string())
        case 116: try literal("true"); value = .bool(true)
        case 102: try literal("false"); value = .bool(false)
        case 110: try literal("null"); value = .null
        case let c? where c == 45 || (48...57).contains(c): value = .number(try number())
        default: throw issue("需要有效的 JSON 值")
        }
        return JSONNode(value: value, range: NSRange(location: start, length: offset - start))
    }
    func literal(_ text: String) throws {
        for char in text.utf16 {
            guard current == char else { throw issue("无效的 JSON 字面量") }
            offset += 1
        }
    }
    func string() throws -> String {
        guard current == 34 else { throw issue("对象键或字符串需要双引号") }
        let start = offset
        offset += 1
        while let char = current {
            if offset % 1024 == 0 { try Task.checkCancellation() }
            if char == 34 {
                offset += 1
                let raw = source.substring(with: NSRange(location: start, length: offset - start))
                guard let result = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else {
                    throw issue("字符串包含无效的转义或 Unicode", at: start)
                }
                return result
            }
            guard char >= 32 else { throw issue("字符串内的换行和控制字符需要转义") }
            if char == 92 {
                offset += 1
                guard let escape = current else { throw issue("不完整的转义") }
                guard [34, 92, 47, 98, 102, 110, 114, 116, 117].contains(escape) else { throw issue("无效的转义") }
                if escape == 117 {
                    for _ in 0..<4 {
                        offset += 1
                        guard let hex = current, (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else { throw issue("Unicode 转义需要四位十六进制数字") }
                    }
                }
            }
            offset += 1
        }
        throw issue("字符串缺少结束引号", at: start)
    }
    func number() throws -> String {
        let start = offset
        if current == 45 { offset += 1 }
        if current == 48 { offset += 1 }
        else {
            guard let c = current, (49...57).contains(c) else { throw issue("无效的 JSON 数字") }
            try digits()
        }
        if current == 46 {
            offset += 1
            guard let c = current, (48...57).contains(c) else { throw issue("小数点后需要数字") }
            try digits()
        }
        if current == 101 || current == 69 {
            offset += 1
            if current == 43 || current == 45 { offset += 1 }
            guard let c = current, (48...57).contains(c) else { throw issue("指数后需要数字") }
            try digits()
        }
        return source.substring(with: NSRange(location: start, length: offset - start))
    }
    func digits() throws {
        while let c = current, (48...57).contains(c) {
            offset += 1
            if offset % 1024 == 0 { try Task.checkCancellation() }
        }
    }
}

private struct JSONParseFrame {
    let object: Bool
    let start: Int
    var members: [JSONMember] = []
    var nodes: [JSONNode] = []
    var keys = Set<Data>()
    var key: String?
}
