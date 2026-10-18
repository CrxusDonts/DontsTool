import Foundation

struct OperationOutput: Sendable {
    var text = ""
    var comparison: JSONComparison?
    var timestamp: TimestampResult?
}
struct OperationSnapshot: Sendable {
    let kind: ToolKind
    let input, left, right, mode, count, target: String
    let comparing, urlSafe, form, bare, uppercase, hyphens, utc: Bool
    let unit: TimestampUnit
    @MainActor init(session: ToolSession) {
        kind = session.kind; input = session.input; left = session.compareLeft; right = session.compareRight
        mode = session.mode; count = session.uuidCount; target = session.target
        comparing = session.comparing; urlSafe = session.urlSafe; form = session.form; bare = session.bare
        uppercase = session.uppercase; hyphens = session.hyphens; utc = session.utc; unit = session.unit
    }
    func execute() throws -> OperationOutput {
        try Task.checkCancellation()
        if kind != .json { try ToolOperations.checkSize(input) }
        switch kind {
        case .json:
            if comparing { return OperationOutput(comparison: try JSONDiff.compare(left, right)) }
            try ToolOperations.checkSize(input)
            switch mode {
            case "escape": return OperationOutput(text: JSONDocument.escape(input))
            case "unescape": return OperationOutput(text: try JSONDocument.unescape(input, bare: bare))
            default: return OperationOutput(text: try JSONDocument.parse(input).formatted(pretty: mode != "minify"))
            }
        case .base64: return OperationOutput(text: try ToolOperations.base64(input, decode: mode == "decode", urlSafe: urlSafe))
        case .url: return OperationOutput(text: try ToolOperations.url(input, decode: mode == "decode", form: form))
        case .hash: return OperationOutput(text: TextTransformers.hash(input, algorithm: HashAlgorithm(rawValue: mode) ?? .sha256))
        case .uuid:
            guard let count = Int(count) else { throw ActionError.invalidInput("数量应为 1–1000 的整数") }
            return OperationOutput(text: try ToolOperations.uuids(count: count, uppercase: uppercase, hyphens: hyphens).joined(separator: "\n"))
        case .timestamp:
            let result = try ToolOperations.timestamps(input, unit: unit, timeZone: utc ? TimeZone(secondsFromGMT: 0)! : .current)
            return OperationOutput(text: result.text, timestamp: result)
        case .translation: return OperationOutput()
        }
    }
}
