import Foundation

public struct JSONDifference: Identifiable, Sendable {
    public enum Kind: String, Sendable { case added = "新增", removed = "删除", modified = "修改" }
    public let id: Int
    public let kind: Kind
    public let path: String
    public let left: String
    public let right: String
    public let leftRange: NSRange?
    public let rightRange: NSRange?
}
public struct JSONComparison: Sendable {
    public var differences: [JSONDifference] = []
    public var added = 0
    public var removed = 0
    public var modified = 0
    public var total: Int { added + removed + modified }
}
public enum JSONDiff {
    public static func compare(_ left: String, _ right: String) throws -> JSONComparison {
        let l: JSONDocument, r: JSONDocument
        do { l = try JSONDocument.parse(left) }
        catch is CancellationError { throw CancellationError() }
        catch { throw JSONSideIssue(side: "左侧", underlying: error) }
        do { r = try JSONDocument.parse(right) }
        catch is CancellationError { throw CancellationError() }
        catch { throw JSONSideIssue(side: "右侧", underlying: error) }
        var comparison = JSONComparison()
        var steps: [JSONDiffStep] = [.pair(l.root, r.root, "")]
        while let step = steps.popLast() {
            try Task.checkCancellation()
            switch step {
            case .object(let a, let b, let keys, let bMap, let index, let path):
                guard index < a.count + b.count else { continue }
                steps.append(.object(a, b, keys, bMap, index + 1, path))
                let member: JSONMember
                let left: JSONNode?, right: JSONNode?
                if index < a.count {
                    member = a[index]; left = member.value; right = bMap[Data(member.key.utf8)]
                } else {
                    member = b[index - a.count]
                    guard !keys.contains(Data(member.key.utf8)) else { continue }
                    left = nil; right = member.value
                }
                let escaped = member.key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                steps.append(.pair(left, right, path + "/" + escaped))
            case .array(let a, let b, let index, let path):
                guard index < max(a.count, b.count) else { continue }
                steps.append(.array(a, b, index + 1, path))
                steps.append(.pair(index < a.count ? a[index] : nil, index < b.count ? b[index] : nil, path + "/\(index)"))
            case .pair(let left, let right, let path):
                if let left, let right {
                    switch (left.value, right.value) {
                    case (.object(let a), .object(let b)):
                        var keys = Set<Data>(), bMap: [Data: JSONNode] = [:]
                        for member in a { try Task.checkCancellation(); keys.insert(Data(member.key.utf8)) }
                        for member in b { try Task.checkCancellation(); bMap[Data(member.key.utf8)] = member.value }
                        steps.append(.object(a, b, keys, bMap, 0, path))
                        continue
                    case (.array(let a), .array(let b)):
                        steps.append(.array(a, b, 0, path))
                        continue
                    case (.string(let a), .string(let b)) where a.utf8.elementsEqual(b.utf8): continue
                    case (.number(let a), .number(let b)):
                        if try canonicalNumber(a) == canonicalNumber(b) { continue }
                    case (.bool(let a), .bool(let b)) where a == b: continue
                    case (.null, .null): continue
                    default: break
                    }
                }
                let kind: JSONDifference.Kind = left == nil ? .added : right == nil ? .removed : .modified
                switch kind { case .added: comparison.added += 1; case .removed: comparison.removed += 1; case .modified: comparison.modified += 1 }
                if comparison.differences.count < 1000 {
                    comparison.differences.append(JSONDifference(id: comparison.total, kind: kind, path: path.isEmpty ? "根节点" : path,
                        left: try left?.rendered(pretty: false) ?? "—", right: try right?.rendered(pretty: false) ?? "—", leftRange: left?.range, rightRange: right?.range))
                }
            }
        }
        return comparison
    }
    private static func canonicalNumber(_ raw: String) throws -> String {
        try Task.checkCancellation()
        let parts = raw.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let negative = parts[0].hasPrefix("-")
        let mantissa = negative ? parts[0].dropFirst() : parts[0][...]
        let fraction = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(mantissa.filter { $0 != "." }.drop(while: { $0 == "0" }))
        if digits.isEmpty { return "0" }
        var adjustment = -(fraction.count > 1 ? fraction[1].count : 0)
        while digits.last == "0" {
            if digits.count % 1024 == 0 { try Task.checkCancellation() }
            digits.removeLast(); adjustment += 1
        }
        let exponent = try integerAdding(parts.count > 1 ? String(parts[1]) : "0", adjustment)
        return (negative ? "-" : "") + String(digits) + "e" + exponent
    }
    // Arbitrary-size signed decimal exponent, plus a source-length-bounded integer.
    private static func integerAdding(_ raw: String, _ adjustment: Int) throws -> String {
        let negative = raw.hasPrefix("-")
        let magnitude = String(raw.filter(\.isNumber).drop(while: { $0 == "0" }))
        if adjustment == 0 { return magnitude.isEmpty ? "0" : (negative ? "-" : "") + magnitude }
        let a = magnitude.isEmpty ? "0" : magnitude
        let b = String(abs(adjustment))
        let bNegative = adjustment < 0
        if negative == bNegative {
            return (negative ? "-" : "") + (try addMagnitude(a, b))
        }
        let aGreater = a.count != b.count ? a.count > b.count : a >= b
        let difference = try subtractMagnitude(aGreater ? a : b, aGreater ? b : a)
        return difference == "0" ? "0" : ((aGreater ? negative : bNegative) ? "-" : "") + difference
    }
    private static func addMagnitude(_ a: String, _ b: String) throws -> String {
        let x = a.reversed().map { $0.wholeNumberValue! }, y = b.reversed().map { $0.wholeNumberValue! }
        var carry = 0, out: [String] = []
        for i in 0..<max(x.count, y.count) {
            if i % 1024 == 0 { try Task.checkCancellation() }
            let value = (i < x.count ? x[i] : 0) + (i < y.count ? y[i] : 0) + carry
            out.append(String(value % 10)); carry = value / 10
        }
        if carry > 0 { out.append(String(carry)) }
        return out.reversed().joined()
    }
    private static func subtractMagnitude(_ a: String, _ b: String) throws -> String {
        let x = a.reversed().map { $0.wholeNumberValue! }, y = b.reversed().map { $0.wholeNumberValue! }
        var borrow = 0, out: [String] = []
        for i in x.indices {
            if i % 1024 == 0 { try Task.checkCancellation() }
            var value = x[i] - (i < y.count ? y[i] : 0) - borrow
            borrow = value < 0 ? 1 : 0
            if value < 0 { value += 10 }
            out.append(String(value))
        }
        let answer = out.reversed().joined().drop(while: { $0 == "0" })
        return answer.isEmpty ? "0" : String(answer)
    }
}
public struct JSONSideIssue: LocalizedError, @unchecked Sendable {
    public let side: String
    public let underlying: Error
    public var errorDescription: String? { side + "：" + underlying.localizedDescription }
}

private enum JSONDiffStep {
    case pair(JSONNode?, JSONNode?, String)
    case object([JSONMember], [JSONMember], Set<Data>, [Data: JSONNode], Int, String)
    case array([JSONNode], [JSONNode], Int, String)
}
