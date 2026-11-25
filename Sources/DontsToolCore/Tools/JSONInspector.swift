import Foundation

public struct JSONOutlineNode: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case object
        case array
        case string
        case number
        case boolean
        case null

        public var badgeText: String {
            switch self {
            case .object: "{}"
            case .array: "[]"
            case .string: "Ab"
            case .number: "123"
            case .boolean: "TF"
            case .null: "∅"
            }
        }

        public var displayName: String {
            switch self {
            case .object: "对象"
            case .array: "数组"
            case .string: "字符串"
            case .number: "数字"
            case .boolean: "布尔"
            case .null: "空值"
            }
        }

        public var isContainer: Bool {
            self == .object || self == .array
        }
    }

    public let id: String
    public let key: String
    public let kind: Kind
    public let childCount: Int
    public let preview: String
    public let range: NSRange
    public let line: Int
    public let depth: Int
    public let children: [JSONOutlineNode]

    public init(
        id: String,
        key: String,
        kind: Kind,
        childCount: Int,
        preview: String,
        range: NSRange,
        line: Int,
        depth: Int,
        children: [JSONOutlineNode]
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.childCount = childCount
        self.preview = preview
        self.range = range
        self.line = line
        self.depth = depth
        self.children = children
    }

    public var countLabel: String? {
        switch kind {
        case .object: "\(childCount) 键"
        case .array: "\(childCount) 项"
        default: nil
        }
    }
}

public struct JSONBreadcrumbSegment: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let range: NSRange

    public init(id: String, label: String, range: NSRange) {
        self.id = id
        self.label = label
        self.range = range
    }
}

public struct JSONFlatOutlineRow: Identifiable, Sendable, Equatable {
    public var id: String { node.id }
    public let node: JSONOutlineNode
    public let depth: Int
    public let isExpanded: Bool

    public init(node: JSONOutlineNode, depth: Int, isExpanded: Bool) {
        self.node = node
        self.depth = depth
        self.isExpanded = isExpanded
    }
}

public enum JSONValidationSummary: Sendable, Equatable {
    case empty
    case valid(rootKind: JSONOutlineNode.Kind, rootCount: Int, nodeCount: Int, lineCount: Int)
    case invalid(message: String, line: Int, column: Int, range: NSRange)

    public var badgeText: String {
        switch self {
        case .empty:
            return "等待输入 JSON"
        case .valid(let rootKind, let rootCount, _, let lineCount):
            switch rootKind {
            case .object:
                return "有效 JSON · 对象 · \(rootCount) 键 · \(lineCount) 行"
            case .array:
                return "有效 JSON · 数组 · \(rootCount) 项 · \(lineCount) 行"
            default:
                return "有效 JSON · \(rootKind.displayName) · \(lineCount) 行"
            }
        case .invalid(_, let line, let column, _):
            return "语法错误 · 第 \(line) 行第 \(column) 列"
        }
    }
}

public struct JSONAnalysis: Sendable, Equatable {
    public static let empty = JSONAnalysis(
        validation: .empty,
        root: nil,
        totalNodes: 0,
        isTruncated: false,
        lineCount: 1
    )

    public let validation: JSONValidationSummary
    public let root: JSONOutlineNode?
    public let totalNodes: Int
    public let isTruncated: Bool
    public let lineCount: Int

    public init(
        validation: JSONValidationSummary,
        root: JSONOutlineNode?,
        totalNodes: Int,
        isTruncated: Bool,
        lineCount: Int
    ) {
        self.validation = validation
        self.root = root
        self.totalNodes = totalNodes
        self.isTruncated = isTruncated
        self.lineCount = lineCount
    }

    public func breadcrumb(atUTF16Offset offset: Int) -> [JSONBreadcrumbSegment] {
        guard let root else { return [] }
        var path: [JSONBreadcrumbSegment] = [
            JSONBreadcrumbSegment(id: root.id, label: "$", range: root.range)
        ]
        var current = root
        while let child = matchingChild(in: current.children, atUTF16Offset: offset) {
            path.append(JSONBreadcrumbSegment(id: child.id, label: child.key, range: child.range))
            current = child
        }
        return path
    }

    public func node(atUTF16Offset offset: Int) -> JSONOutlineNode? {
        guard let root else { return nil }
        var current = root
        while let child = matchingChild(in: current.children, atUTF16Offset: offset) {
            current = child
        }
        return current
    }

    public func filteredRoot(matching query: String) -> JSONOutlineNode? {
        guard let root else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return root }
        return filterNode(root, query: trimmed)
    }

    public func flattenedRows(matching query: String, expandedIDs: Set<String>) -> [JSONFlatOutlineRow] {
        guard let filtered = filteredRoot(matching: query) else { return [] }
        let expandAllMatches = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var rows: [JSONFlatOutlineRow] = []
        var stack: [(node: JSONOutlineNode, depth: Int)] = [(filtered, 0)]
        while let current = stack.popLast() {
            let hasChildren = !current.node.children.isEmpty
            let isExpanded = hasChildren && (expandAllMatches || expandedIDs.contains(current.node.id))
            rows.append(JSONFlatOutlineRow(node: current.node, depth: current.depth, isExpanded: isExpanded))
            if isExpanded {
                for child in current.node.children.reversed() {
                    stack.append((child, current.depth + 1))
                }
            }
        }
        return rows
    }

    public func strictAncestorIDs(of targetID: String) -> [String] {
        guard let root, root.id != targetID else { return [] }
        var ancestors: [String] = []
        _ = collectStrictAncestors(from: root, targetID: targetID, ancestors: &ancestors)
        return ancestors.reversed()
    }

    public func nodeLookupDictionary() -> [String: JSONOutlineNode] {
        guard let root else { return [:] }
        var map: [String: JSONOutlineNode] = [:]
        map.reserveCapacity(totalNodes)
        var stack: [JSONOutlineNode] = [root]
        while let current = stack.popLast() {
            map[current.id] = current
            for child in current.children {
                stack.append(child)
            }
        }
        return map
    }

    private func collectStrictAncestors(
        from node: JSONOutlineNode,
        targetID: String,
        ancestors: inout [String]
    ) -> Bool {
        for child in node.children {
            if child.id == targetID || collectStrictAncestors(from: child, targetID: targetID, ancestors: &ancestors) {
                ancestors.append(node.id)
                return true
            }
        }
        return false
    }

    private func matchingChild(in children: [JSONOutlineNode], atUTF16Offset offset: Int) -> JSONOutlineNode? {
        if let strict = children.first(where: {
            offset >= $0.range.location && offset < NSMaxRange($0.range)
        }) {
            return strict
        }
        return children.first(where: {
            offset == NSMaxRange($0.range)
        })
    }

    private func filterNode(_ node: JSONOutlineNode, query: String) -> JSONOutlineNode? {
        let selfMatches = node.key.localizedCaseInsensitiveContains(query)
            || node.preview.localizedCaseInsensitiveContains(query)
            || node.id.localizedCaseInsensitiveContains(query)
        let matchingChildren = node.children.compactMap { filterNode($0, query: query) }
        if !matchingChildren.isEmpty {
            return JSONOutlineNode(
                id: node.id,
                key: node.key,
                kind: node.kind,
                childCount: node.childCount,
                preview: node.preview,
                range: node.range,
                line: node.line,
                depth: node.depth,
                children: matchingChildren
            )
        }
        return selfMatches ? node : nil
    }
}

public enum JSONInspector: Sendable {
    public static let maxOutlineNodes = 4_000

    public static func analyze(_ source: String) -> JSONAnalysis {
        let lines = TextLineIndex(source)
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return JSONAnalysis(
                validation: .empty,
                root: nil,
                totalNodes: 0,
                isTruncated: false,
                lineCount: lines.lineCount
            )
        }

        do {
            let document = try JSONDocument.parse(source)
            var state = BuildState(lines: lines, maxNodes: maxOutlineNodes)
            let root = state.buildNode(
                document.root,
                key: "root",
                path: "$",
                depth: 0
            )
            let validation: JSONValidationSummary = if let root {
                .valid(
                    rootKind: root.kind,
                    rootCount: root.childCount,
                    nodeCount: state.totalNodes,
                    lineCount: lines.lineCount
                )
            } else {
                .empty
            }
            return JSONAnalysis(
                validation: validation,
                root: root,
                totalNodes: state.totalNodes,
                isTruncated: state.isTruncated,
                lineCount: lines.lineCount
            )
        } catch let issue as JSONIssue {
            return JSONAnalysis(
                validation: .invalid(
                    message: issue.message,
                    line: issue.line,
                    column: issue.column,
                    range: issue.range
                ),
                root: nil,
                totalNodes: 0,
                isTruncated: false,
                lineCount: lines.lineCount
            )
        } catch {
            return JSONAnalysis(
                validation: .invalid(
                    message: error.localizedDescription,
                    line: 1,
                    column: 1,
                    range: NSRange(location: 0, length: 0)
                ),
                root: nil,
                totalNodes: 0,
                isTruncated: false,
                lineCount: lines.lineCount
            )
        }
    }

    private struct BuildState {
        let lines: TextLineIndex
        let maxNodes: Int
        var totalNodes = 0
        var isTruncated = false

        mutating func buildNode(
            _ node: JSONNode,
            key: String,
            path: String,
            depth: Int
        ) -> JSONOutlineNode? {
            guard totalNodes < maxNodes else {
                isTruncated = true
                return nil
            }
            totalNodes += 1

            let line = lines.lineNumber(atUTF16Offset: node.range.location)
            switch node.value {
            case .object(let members):
                var children: [JSONOutlineNode] = []
                children.reserveCapacity(min(members.count, max(0, maxNodes - totalNodes)))
                for member in members {
                    let childPath = memberPath(parent: path, key: member.key)
                    guard let child = buildNode(member.value, key: member.key, path: childPath, depth: depth + 1) else {
                        break
                    }
                    children.append(child)
                }
                return JSONOutlineNode(
                    id: path,
                    key: key,
                    kind: .object,
                    childCount: members.count,
                    preview: "",
                    range: node.range,
                    line: line,
                    depth: depth,
                    children: children
                )

            case .array(let items):
                var children: [JSONOutlineNode] = []
                children.reserveCapacity(min(items.count, max(0, maxNodes - totalNodes)))
                for (index, item) in items.enumerated() {
                    let indexKey = "[\(index)]"
                    let childPath = "\(path)\(indexKey)"
                    guard let child = buildNode(item, key: indexKey, path: childPath, depth: depth + 1) else {
                        break
                    }
                    children.append(child)
                }
                return JSONOutlineNode(
                    id: path,
                    key: key,
                    kind: .array,
                    childCount: items.count,
                    preview: "",
                    range: node.range,
                    line: line,
                    depth: depth,
                    children: children
                )

            case .string(let text):
                return JSONOutlineNode(
                    id: path,
                    key: key,
                    kind: .string,
                    childCount: 0,
                    preview: truncatedScalar(JSONDocument.escape(singleLine(text))),
                    range: node.range,
                    line: line,
                    depth: depth,
                    children: []
                )

            case .number(let raw):
                return JSONOutlineNode(
                    id: path,
                    key: key,
                    kind: .number,
                    childCount: 0,
                    preview: truncatedScalar(raw),
                    range: node.range,
                    line: line,
                    depth: depth,
                    children: []
                )

            case .bool(let flag):
                return JSONOutlineNode(
                    id: path,
                    key: key,
                    kind: .boolean,
                    childCount: 0,
                    preview: flag ? "true" : "false",
                    range: node.range,
                    line: line,
                    depth: depth,
                    children: []
                )

            case .null:
                return JSONOutlineNode(
                    id: path,
                    key: key,
                    kind: .null,
                    childCount: 0,
                    preview: "null",
                    range: node.range,
                    line: line,
                    depth: depth,
                    children: []
                )
            }
        }

        private func memberPath(parent: String, key: String) -> String {
            if isSimpleIdentifier(key) {
                return "\(parent).\(key)"
            }
            let escaped = key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\(parent)[\"\(escaped)\"]"
        }

        private func isSimpleIdentifier(_ key: String) -> Bool {
            guard !key.isEmpty else { return false }
            for scalar in key.unicodeScalars {
                if scalar == "_" || scalar == "-" { continue }
                if CharacterSet.alphanumerics.contains(scalar) { continue }
                return false
            }
            return true
        }

        private func singleLine(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }

        private func truncatedScalar(_ text: String) -> String {
            guard text.count > 96 else { return text }
            return String(text.prefix(95)) + "…"
        }
    }
}
