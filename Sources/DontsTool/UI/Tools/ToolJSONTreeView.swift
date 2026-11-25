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
    @State private var visibleRows: [JSONFlatOutlineRow] = []
    @State private var nodeByID: [String: JSONOutlineNode] = [:]

    private var activeSelectedID: String? {
        manualSelectedID ?? selectedPath
    }

    private var selectedNode: JSONOutlineNode? {
        if let activeSelectedID, let found = nodeByID[activeSelectedID] {
            return found
        }
        return analysis.root
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
        .onAppear {
            rebuildIndex()
            resetDefaultExpansion()
        }
        .onChange(of: analysis) { _, _ in
            rebuildIndex()
            if expandedIDs.isEmpty {
                resetDefaultExpansion()
            } else {
                rebuildVisibleRows()
            }
        }
        .onChange(of: searchQuery) { _, _ in
            rebuildVisibleRows()
        }
        .onChange(of: selectedPath) { _, newPath in
            manualSelectedID = nil
            guard let newPath else { return }
            let ancestors = analysis.strictAncestorIDs(of: newPath)
            var changed = false
            for ancestorID in ancestors where expandedIDs.insert(ancestorID).inserted {
                changed = true
            }
            if changed {
                rebuildVisibleRows()
            }
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
                            JSONTreeRowView(
                                row: row,
                                compact: compact,
                                isSelected: activeSelectedID == row.id,
                                hasJumpToCode: onJumpToCode != nil,
                                onToggleExpand: {
                                    toggleExpand(row.id)
                                },
                                onSelect: {
                                    manualSelectedID = row.id
                                    if compact {
                                        onSelectNode(row.node)
                                    }
                                },
                                onCopyPath: {
                                    onCopyText(row.id)
                                },
                                onCopyValue: {
                                    onCopyText(rawJSONSlice(for: row.node))
                                },
                                onJumpToCode: {
                                    manualSelectedID = row.id
                                    onJumpToCode?(row.node)
                                }
                            )
                            .equatable()
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
            }
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
                    .foregroundStyle(Self.kindColor(for: selectedNode.kind))
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

    private func rebuildIndex() {
        nodeByID = analysis.nodeLookupDictionary()
    }

    private func rebuildVisibleRows() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visibleRows = analysis.flattenedRows(matching: searchQuery, expandedIDs: expandedIDs)
        }
    }

    private func toggleExpand(_ id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
        rebuildVisibleRows()
    }

    private func expandAll() {
        guard let root = analysis.root else { return }
        var ids: Set<String> = []
        collectContainerIDs(root, maxDepth: nil, into: &ids)
        expandedIDs = ids
        rebuildVisibleRows()
    }

    private func collapseAll() {
        expandedIDs.removeAll()
        rebuildVisibleRows()
    }

    private func expandToDepth(_ maxDepth: Int) {
        guard let root = analysis.root else { return }
        var ids: Set<String> = []
        collectContainerIDs(root, maxDepth: maxDepth, into: &ids)
        expandedIDs = ids
        rebuildVisibleRows()
    }

    private func resetDefaultExpansion() {
        guard let root = analysis.root else {
            expandedIDs = ["$"]
            visibleRows = []
            return
        }
        var ids: Set<String> = []
        collectContainerIDs(root, maxDepth: 1, into: &ids)
        expandedIDs = ids
        rebuildVisibleRows()
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

    private func rawJSONSlice(for node: JSONOutlineNode) -> String {
        let source = sourceText as NSString
        guard node.range.location >= 0, NSMaxRange(node.range) <= source.length else {
            return node.preview
        }
        return source.substring(with: node.range)
    }

    static func kindColor(for kind: JSONOutlineNode.Kind) -> Color {
        switch kind {
        case .object: ToolTheme.syntaxKey
        case .array: ToolTheme.syntaxBoolean
        case .string: ToolTheme.syntaxString
        case .number: ToolTheme.syntaxNumber
        case .boolean: ToolTheme.syntaxBoolean
        case .null: ToolTheme.syntaxNull
        }
    }
}

private struct JSONTreeRowView: View, @preconcurrency Equatable {
    let row: JSONFlatOutlineRow
    let compact: Bool
    let isSelected: Bool
    let hasJumpToCode: Bool
    let onToggleExpand: () -> Void
    let onSelect: () -> Void
    let onCopyPath: () -> Void
    let onCopyValue: () -> Void
    let onJumpToCode: () -> Void

    @State private var isHovered = false
    @State private var isChevronHovered = false

    static func == (lhs: JSONTreeRowView, rhs: JSONTreeRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.compact == rhs.compact
            && lhs.isSelected == rhs.isSelected
            && lhs.hasJumpToCode == rhs.hasJumpToCode
    }

    var body: some View {
        let node = row.node
        let hasChildren = !node.children.isEmpty
        let isCollapsedContainer = hasChildren && !row.isExpanded

        HStack(spacing: 6) {
            Color.clear
                .frame(width: CGFloat(row.depth) * (compact ? 12 : 16), height: 1)

            if hasChildren {
                Button(action: onToggleExpand) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(
                            isCollapsedContainer
                                ? ToolTheme.foldCollapsedText
                                : (isChevronHovered ? ToolTheme.ink : ToolTheme.secondary)
                        )
                        .frame(width: 26, height: 26)
                        .background(
                            isCollapsedContainer
                                ? ToolTheme.foldCollapsedFill
                                : (isChevronHovered ? ToolTheme.foldHoverFill : Theme.controlFill.opacity(0.55)),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isCollapsedContainer ? ToolTheme.foldCollapsedBorder : Color.clear, lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isChevronHovered = $0 }
                .accessibilityLabel(row.isExpanded ? "折叠 \(node.key)" : "展开 \(node.key)")
            } else {
                Color.clear.frame(width: 26, height: 26)
            }

            HStack(spacing: 6) {
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
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            if isHovered && !compact {
                HStack(spacing: 4) {
                    Button(action: onCopyPath) {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: 10.5))
                            .foregroundStyle(ToolTheme.secondary)
                            .frame(width: 22, height: 22)
                            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("复制 JSONPath")

                    Button(action: onCopyValue) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10.5))
                            .foregroundStyle(ToolTheme.secondary)
                            .frame(width: 22, height: 22)
                            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("复制此节点值")

                    if hasJumpToCode {
                        Button(action: onJumpToCode) {
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
        .frame(height: compact ? 28 : 30)
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
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("复制路径（\(node.id)）", action: onCopyPath)
            Button("复制值", action: onCopyValue)
            if hasJumpToCode {
                Button("在代码中定位", action: onJumpToCode)
            }
            if hasChildren {
                Divider()
                Button(row.isExpanded ? "折叠此节点" : "展开此节点", action: onToggleExpand)
            }
        }
    }

    private func typeBadge(for kind: JSONOutlineNode.Kind) -> some View {
        let color = ToolJSONTreeView.kindColor(for: kind)
        return Text(kind.badgeText)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 24, height: 17)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    private func previewColor(for kind: JSONOutlineNode.Kind) -> Color {
        switch kind {
        case .object, .array: ToolTheme.secondary
        default: ToolJSONTreeView.kindColor(for: kind)
        }
    }
}
