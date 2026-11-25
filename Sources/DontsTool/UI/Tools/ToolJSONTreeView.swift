import DontsToolCore
import SwiftUI

struct ToolJSONTreeView: View {
    let analysis: JSONAnalysis
    let sourceText: String
    let compact: Bool
    let selectedPath: String?
    let onSelectNode: (JSONOutlineNode) -> Void
    let onJumpToCode: ((JSONOutlineNode) -> Void)?
    let onCopyText: (String) -> Void
    let onPasteJSON: (() -> Void)?

    @State private var searchQuery = ""
    @State private var expandedIDs: Set<String> = ["$"]
    @State private var manualSelectedID: String?
    @State private var hoveredRowID: String?
    @State private var hoveredChevronID: String?

    private struct FlatRow: Identifiable {
        let id: String
        let node: JSONOutlineNode
        let depth: Int
        let isExpanded: Bool
    }

    private var activeSelectedID: String? {
        manualSelectedID ?? selectedPath
    }

    private var filteredRoot: JSONOutlineNode? {
        analysis.filteredRoot(matching: searchQuery)
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleRows: [FlatRow] {
        guard let root = filteredRoot else { return [] }
        var rows: [FlatRow] = []
        appendRows(from: root, depth: 0, into: &rows)
        return rows
    }

    private var selectedNode: JSONOutlineNode? {
        guard let root = analysis.root else { return nil }
        if let activeSelectedID, let found = findNode(withID: activeSelectedID, in: root) {
            return found
        }
        return root
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            ToolTheme.border.frame(height: 0.5)
            searchBar
            ToolTheme.border.frame(height: 0.5)
            treeContent
            ToolTheme.border.frame(height: 0.5)
            footerBar
        }
        .background(ToolTheme.editor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ToolTheme.border, lineWidth: 0.5))
        .onChange(of: analysis.root?.id) { _, _ in
            resetDefaultExpansion()
        }
        .onChange(of: analysis.totalNodes) { _, _ in
            if expandedIDs.isEmpty {
                resetDefaultExpansion()
            }
        }
        .onChange(of: selectedPath) { _, newPath in
            manualSelectedID = nil
            if let newPath, let root = analysis.root {
                for ancestorID in ancestorPathIDs(to: newPath, in: root) {
                    expandedIDs.insert(ancestorID)
                }
            }
        }
        .onAppear {
            resetDefaultExpansion()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ToolTheme.secondary)
            Text("结构树")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ToolTheme.ink)
            if analysis.totalNodes > 0 {
                Text(analysis.isTruncated ? "\(analysis.totalNodes)+ 节点" : "\(analysis.totalNodes) 节点")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ToolTheme.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.controlFill, in: Capsule())
            }
            Spacer(minLength: 4)
            if !compact {
                ToolQuietButton(title: "展开全部", systemImage: "arrow.up.left.and.arrow.down.right") {
                    expandAll()
                }
                ToolQuietButton(title: "折叠全部", systemImage: "arrow.down.right.and.arrow.up.left") {
                    collapseAll()
                }
                ToolQuietButton(title: "展开 2 层") {
                    expandToDepth(2)
                }
            } else if analysis.root != nil {
                ToolQuietButton(title: "", systemImage: "arrow.down.right.and.arrow.up.left") {
                    collapseAll()
                }
                .help("折叠全部节点")
                ToolQuietButton(title: "", systemImage: "arrow.up.left.and.arrow.down.right") {
                    expandAll()
                }
                .help("展开全部节点")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(ToolTheme.toolbar)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            TextField("筛选键、值或路径…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(ToolTheme.ink)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(ToolTheme.gutter)
    }

    @ViewBuilder
    private var treeContent: some View {
        switch analysis.validation {
        case .empty:
            VStack(spacing: 10) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                Text("输入或粘贴 JSON 后可按树形层级浏览与检索")
                    .font(.system(size: 12))
                    .foregroundStyle(ToolTheme.secondary)
                    .multilineTextAlignment(.center)
                if let onPasteJSON {
                    ToolQuietButton(title: "从剪贴板粘贴", systemImage: "doc.on.clipboard", action: onPasteJSON)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .invalid(let message, let line, let column, _):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.warning)
                Text("第 \(line) 行第 \(column) 列存在语法错误")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ToolTheme.ink)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToolTheme.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .valid:
            if visibleRows.isEmpty {
                VStack(spacing: 8) {
                    Text("没有匹配「\(searchQuery)」的节点")
                        .font(.system(size: 12))
                        .foregroundStyle(ToolTheme.secondary)
                    ToolQuietButton(title: "清除筛选") {
                        searchQuery = ""
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visibleRows) { row in
                            treeRow(row)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private func treeRow(_ row: FlatRow) -> some View {
        let node = row.node
        let isSelected = activeSelectedID == node.id
        let isHovered = hoveredRowID == node.id
        let hasChildren = !node.children.isEmpty

        return HStack(spacing: 6) {
            Color.clear
                .frame(width: CGFloat(row.depth) * (compact ? 12 : 16), height: 1)

            if hasChildren {
                Button {
                    toggleExpand(node.id)
                } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(hoveredChevronID == node.id ? ToolTheme.ink : ToolTheme.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            hoveredChevronID == node.id ? ToolTheme.foldHoverFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredChevronID = hovering ? node.id : (hoveredChevronID == node.id ? nil : hoveredChevronID)
                }
            } else {
                Color.clear.frame(width: 22, height: 22)
            }

            typeBadge(for: node.kind)

            Text(node.key)
                .font(.system(size: compact ? 12 : 12.5, weight: hasChildren ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(hasChildren ? ToolTheme.ink : ToolTheme.syntaxKey)
                .lineLimit(1)
                .truncationMode(.tail)

            if let countLabel = node.countLabel {
                Text(countLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isSelected ? ToolTheme.foldCollapsedText : ToolTheme.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        isSelected ? ToolTheme.foldCollapsedFill : Theme.controlFill,
                        in: Capsule()
                    )
            } else {
                Text(node.preview)
                    .font(.system(size: compact ? 11.5 : 12, design: .monospaced))
                    .foregroundStyle(previewColor(for: node.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if isHovered && !compact {
                HStack(spacing: 4) {
                    Button {
                        onCopyText(node.id)
                    } label: {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: 10.5))
                            .foregroundStyle(ToolTheme.secondary)
                            .frame(width: 22, height: 22)
                            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("复制 JSONPath")

                    Button {
                        onCopyText(rawJSONSlice(for: node))
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10.5))
                            .foregroundStyle(ToolTheme.secondary)
                            .frame(width: 22, height: 22)
                            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("复制此节点值")

                    if let onJumpToCode {
                        Button {
                            onJumpToCode(node)
                        } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 10.5))
                                .foregroundStyle(ToolTheme.accent)
                                .frame(width: 22, height: 22)
                                .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help("在代码中定位")
                    }
                }
            } else if compact {
                Text("L\(node.line)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: compact ? 27 : 30)
        .background(
            isSelected
                ? Theme.accentFill
                : (isHovered ? Theme.rowHover : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Theme.accentBorder : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredRowID = hovering ? node.id : (hoveredRowID == node.id ? nil : hoveredRowID)
        }
        .onTapGesture(count: 2) {
            if hasChildren {
                toggleExpand(node.id)
            } else {
                manualSelectedID = node.id
                if let onJumpToCode {
                    onJumpToCode(node)
                } else {
                    onSelectNode(node)
                }
            }
        }
        .onTapGesture {
            manualSelectedID = node.id
            onSelectNode(node)
        }
        .contextMenu {
            Button("复制路径（\(node.id)）") {
                onCopyText(node.id)
            }
            Button("复制值") {
                onCopyText(rawJSONSlice(for: node))
            }
            if let onJumpToCode {
                Button("在代码中定位") {
                    onJumpToCode(node)
                }
            }
            if hasChildren {
                Divider()
                Button(row.isExpanded ? "折叠此节点" : "展开此节点") {
                    toggleExpand(node.id)
                }
            }
        }
    }

    private func typeBadge(for kind: JSONOutlineNode.Kind) -> some View {
        let color = badgeColor(for: kind)
        return Text(kind.badgeText)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 24, height: 17)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    private func badgeColor(for kind: JSONOutlineNode.Kind) -> Color {
        switch kind {
        case .object: ToolTheme.syntaxKey
        case .array: ToolTheme.syntaxBoolean
        case .string: ToolTheme.syntaxString
        case .number: ToolTheme.syntaxNumber
        case .boolean: ToolTheme.syntaxBoolean
        case .null: ToolTheme.syntaxNull
        }
    }

    private func previewColor(for kind: JSONOutlineNode.Kind) -> Color {
        switch kind {
        case .object, .array: ToolTheme.secondary
        case .string: ToolTheme.syntaxString
        case .number: ToolTheme.syntaxNumber
        case .boolean: ToolTheme.syntaxBoolean
        case .null: ToolTheme.syntaxNull
        }
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            if let selectedNode {
                Text("选中：\(selectedNode.id)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ToolTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(selectedNode.kind.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(badgeColor(for: selectedNode.kind))
                Button {
                    onCopyText(selectedNode.id)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(ToolTheme.secondary)
                }
                .buttonStyle(.plain)
                .help("复制路径")
            } else {
                Text("点击节点定位或右键复制路径")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(ToolTheme.gutter)
    }

    private func appendRows(from node: JSONOutlineNode, depth: Int, into rows: inout [FlatRow]) {
        let isExpanded = isSearching ? true : expandedIDs.contains(node.id)
        rows.append(FlatRow(id: node.id, node: node, depth: depth, isExpanded: isExpanded))
        guard isExpanded else { return }
        for child in node.children {
            appendRows(from: child, depth: depth + 1, into: &rows)
        }
    }

    private func toggleExpand(_ id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    private func expandAll() {
        guard let root = analysis.root else { return }
        var ids: Set<String> = []
        collectContainerIDs(root, maxDepth: nil, into: &ids)
        expandedIDs = ids
    }

    private func collapseAll() {
        expandedIDs.removeAll()
    }

    private func expandToDepth(_ maxDepth: Int) {
        guard let root = analysis.root else { return }
        var ids: Set<String> = []
        collectContainerIDs(root, maxDepth: maxDepth, into: &ids)
        expandedIDs = ids
    }

    private func resetDefaultExpansion() {
        guard let root = analysis.root else {
            expandedIDs = ["$"]
            return
        }
        var ids: Set<String> = []
        collectContainerIDs(root, maxDepth: 1, into: &ids)
        expandedIDs = ids
    }

    private func collectContainerIDs(_ node: JSONOutlineNode, maxDepth: Int?, into ids: inout Set<String>) {
        guard !node.children.isEmpty else { return }
        if let maxDepth, node.depth >= maxDepth {
            return
        }
        ids.insert(node.id)
        for child in node.children {
            collectContainerIDs(child, maxDepth: maxDepth, into: &ids)
        }
    }

    private func findNode(withID id: String, in node: JSONOutlineNode) -> JSONOutlineNode? {
        if node.id == id { return node }
        for child in node.children {
            if let match = findNode(withID: id, in: child) {
                return match
            }
        }
        return nil
    }

    private func ancestorPathIDs(to targetID: String, in node: JSONOutlineNode) -> [String] {
        if node.id == targetID { return [node.id] }
        for child in node.children {
            let sub = ancestorPathIDs(to: targetID, in: child)
            if !sub.isEmpty {
                return [node.id] + sub
            }
        }
        return []
    }

    private func rawJSONSlice(for node: JSONOutlineNode) -> String {
        let source = sourceText as NSString
        guard node.range.location >= 0, NSMaxRange(node.range) <= source.length else {
            return node.preview
        }
        return source.substring(with: node.range)
    }
}
