import DontsToolCore
import SwiftUI

extension ToolWorkspaceView {
    // Keep native editor sets alive so mode switches preserve selection and undo targets.
    var jsonBody: some View {
        ZStack {
            jsonComparisonBody
                .opacity(jsonViewMode == .compare ? 1 : 0)
                .allowsHitTesting(jsonViewMode == .compare)
                .accessibilityHidden(jsonViewMode != .compare)

            jsonCodeBody
                .opacity(jsonViewMode == .code ? 1 : 0)
                .allowsHitTesting(jsonViewMode == .code)
                .accessibilityHidden(jsonViewMode != .code)

            if jsonViewMode == .tree {
                jsonTreeBody
            }
        }
    }

    private var jsonCodeBody: some View {
        HSplitView {
            jsonCodeEditorWell
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            if showJSONOutline {
                ToolJSONTreeView(
                    analysis: jsonAnalysis,
                    sourceText: session.input,
                    compact: true,
                    selectedPath: jsonAnalysis.node(atUTF16Offset: cursorPosition.utf16Offset)?.id,
                    onSelectNode: { jumpToCodeNode($0, switchToCode: false) },
                    onJumpToCode: { jumpToCodeNode($0, switchToCode: false) },
                    onCopyText: copy,
                    onPasteJSON: pasteFormattedJSON
                )
                .frame(minWidth: 230, idealWidth: 276, maxWidth: 380)
                .padding(4)
            }
        }
    }

    private var jsonCodeEditorWell: some View {
        let segments = jsonAnalysis.breadcrumb(atUTF16Offset: cursorPosition.utf16Offset)
        let fullPath = segments.last?.id ?? "$"

        return VStack(spacing: 0) {
            JSONBreadcrumbBar(
                segments: segments,
                fullPath: fullPath,
                onSelectSegment: { segment in
                    inputSelection = EditorSelection(range: segment.range)
                },
                onCopyPath: copy
            )

            ToolTheme.border.frame(height: 0.5)

            ToolTextEditor(
                text: $session.input,
                json: true,
                wrap: wrap,
                folding: true,
                selection: inputSelection,
                foldCommand: codeFoldCommand,
                active: jsonViewMode == .code,
                editRevision: draftEditor.revision,
                sharedUndoManager: draftEditor.undoManager,
                label: "JSON",
                onCursorChange: { position in
                    cursorPosition = position
                }
            )
        }
        .frame(minWidth: 230, minHeight: 120)
        .background(ToolTheme.editor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ToolTheme.border, lineWidth: 0.5)
        )
        .padding(4)
    }

    private var jsonTreeBody: some View {
        ToolJSONTreeView(
            analysis: jsonAnalysis,
            sourceText: session.input,
            compact: false,
            selectedPath: jsonAnalysis.node(atUTF16Offset: cursorPosition.utf16Offset)?.id,
            onSelectNode: { jumpToCodeNode($0, switchToCode: false) },
            onJumpToCode: { jumpToCodeNode($0, switchToCode: true) },
            onCopyText: copy,
            onPasteJSON: pasteFormattedJSON
        )
        .padding(4)
    }

    private var jsonComparisonBody: some View {
        let lineDiffs = comparisonLineKinds()

        return VSplitView {
            HSplitView {
                ToolEditorPane(
                    title: document.leftTitle,
                    text: $session.compareLeft,
                    json: true,
                    wrap: wrap,
                    folding: true,
                    selection: leftSelection,
                    foldCommand: compareFoldCommand,
                    diffLineKinds: lineDiffs.left,
                    statusDotColor: validityColor(for: leftAnalysis),
                    subtitle: validitySubtitle(for: leftAnalysis),
                    name: $document.leftTitle,
                    active: jsonViewMode == .compare,
                    editRevision: draftEditor.revision,
                    undoManager: draftEditor.undoManager
                ) {
                    ToolQuietButton(title: "粘贴", systemImage: "doc.on.clipboard") {
                        paste(into: &session.compareLeft)
                    }
                    ToolQuietButton(title: "清空", systemImage: "trash", disabled: session.compareLeft.isEmpty) {
                        session.compareLeft = ""
                    }
                }
                ToolEditorPane(
                    title: document.rightTitle,
                    text: $session.compareRight,
                    json: true,
                    wrap: wrap,
                    folding: true,
                    selection: rightSelection,
                    foldCommand: compareFoldCommand,
                    diffLineKinds: lineDiffs.right,
                    statusDotColor: validityColor(for: rightAnalysis),
                    subtitle: validitySubtitle(for: rightAnalysis),
                    name: $document.rightTitle,
                    active: jsonViewMode == .compare,
                    editRevision: draftEditor.revision,
                    undoManager: draftEditor.undoManager
                ) {
                    ToolQuietButton(title: "粘贴", systemImage: "doc.on.clipboard") {
                        paste(into: &session.compareRight)
                    }
                    ToolQuietButton(title: "清空", systemImage: "trash", disabled: session.compareRight.isEmpty) {
                        session.compareRight = ""
                    }
                }
            }
            .frame(minHeight: 200)

            differences
                .frame(minHeight: 145, idealHeight: 215)
                .background(ToolTheme.editor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ToolTheme.border, lineWidth: 0.5))
                .padding(4)
        }
    }

    private var differences: some View {
        let filtered = filteredDifferences

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("结构差异")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ToolTheme.ink)

                if let comparison = session.comparison {
                    diffFilterPill(
                        title: "全部 \(comparison.total)",
                        kind: nil,
                        tint: ToolTheme.secondary
                    )
                    diffFilterPill(
                        title: "+ 新增 \(comparison.added)",
                        kind: .added,
                        tint: ToolTheme.diffAdded
                    )
                    diffFilterPill(
                        title: "- 删除 \(comparison.removed)",
                        kind: .removed,
                        tint: ToolTheme.diffRemoved
                    )
                    diffFilterPill(
                        title: "~ 修改 \(comparison.modified)",
                        kind: .modified,
                        tint: ToolTheme.diffModified
                    )
                }

                Spacer()

                Text(session.comparison == nil ? "尚未对比" : "点击差异行定位双侧光标")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(ToolTheme.toolbar)

            ToolTheme.border.frame(height: 0.5)

            if session.comparison != nil && session.hasStaleResult {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text("左侧或右侧内容已修改，旧对比结果已过期，请点击「对比」刷新")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warning.opacity(0.08))
                ToolTheme.border.frame(height: 0.5)
            }

            if let comparison = session.comparison {
                if comparison.total == 0 {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.success)
                        Text("两侧 JSON 结构与值完全一致")
                            .font(.system(size: 12))
                            .foregroundStyle(ToolTheme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 12) {
                        Text("类型").frame(width: 70, alignment: .leading)
                        Text("JSON 路径").frame(width: 190, alignment: .leading)
                        Text("左侧值（基准）").frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 16)
                        Text("右侧值（目标）").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(ToolTheme.gutter)

                    ToolTheme.border.frame(height: 0.5)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { difference in
                                Button {
                                    selectDifference(difference)
                                } label: {
                                    HStack(spacing: 12) {
                                        diffKindBadge(difference.kind)
                                            .frame(width: 70, alignment: .leading)
                                        Text(difference.path)
                                            .foregroundStyle(ToolTheme.ink)
                                            .frame(width: 190, alignment: .leading)
                                        Text(difference.left)
                                            .foregroundStyle(difference.kind == .removed ? ToolTheme.diffRemoved : ToolTheme.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.tertiary)
                                            .frame(width: 16)
                                        Text(difference.right)
                                            .foregroundStyle(difference.kind == .added ? ToolTheme.diffAdded : ToolTheme.ink)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(selectedDifference == difference.id ? Theme.accentFill : Color.clear)
                                .disabled(!session.isFresh)

                                ToolTheme.border.frame(height: 0.5)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Text("编辑或粘贴两侧 JSON 后点击「对比」")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(ToolTheme.ink)
                    Text("对象对比忽略键顺序，数组按索引逐项对比；点击任意差异可立即同步定位左右编辑框。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ToolTheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            }
            Spacer(minLength: 0)
        }
    }

    private func diffFilterPill(title: String, kind: JSONDifference.Kind?, tint: Color) -> some View {
        let active = diffFilter == kind
        return Button {
            diffFilter = kind
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? tint : ToolTheme.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? tint.opacity(0.14) : Theme.controlFill, in: Capsule())
                .overlay(Capsule().strokeBorder(active ? tint.opacity(0.36) : Color.clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func diffKindBadge(_ kind: JSONDifference.Kind) -> some View {
        let color = diffColor(for: kind)
        let prefix = switch kind {
        case .added: "+"
        case .removed: "-"
        case .modified: "~"
        }
        return Text("\(prefix) \(kind.rawValue)")
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func diffColor(for kind: JSONDifference.Kind) -> Color {
        switch kind {
        case .added: ToolTheme.diffAdded
        case .removed: ToolTheme.diffRemoved
        case .modified: ToolTheme.diffModified
        }
    }

    private func comparisonLineKinds() -> (left: [Int: JSONDifference.Kind], right: [Int: JSONDifference.Kind]) {
        guard let comparison = session.comparison, session.isFresh else {
            return ([:], [:])
        }
        let leftIndex = TextLineIndex(session.compareLeft)
        let rightIndex = TextLineIndex(session.compareRight)
        var leftMap: [Int: JSONDifference.Kind] = [:]
        var rightMap: [Int: JSONDifference.Kind] = [:]

        for diff in comparison.differences {
            if let range = diff.leftRange {
                let line = leftIndex.lineNumber(atUTF16Offset: range.location)
                if leftMap[line] == nil || diff.kind == .modified {
                    leftMap[line] = diff.kind
                }
            }
            if let range = diff.rightRange {
                let line = rightIndex.lineNumber(atUTF16Offset: range.location)
                if rightMap[line] == nil || diff.kind == .modified {
                    rightMap[line] = diff.kind
                }
            }
        }
        return (leftMap, rightMap)
    }

    private func validityColor(for analysis: JSONAnalysis) -> Color? {
        switch analysis.validation {
        case .empty: return nil
        case .valid: return Theme.success
        case .invalid: return ToolTheme.diffRemoved
        }
    }

    private func validitySubtitle(for analysis: JSONAnalysis) -> String? {
        switch analysis.validation {
        case .empty: return nil
        case .valid(_, _, _, let lineCount): return "\(lineCount) 行"
        case .invalid(_, let line, let col, _): return "第 \(line):\(col) 行有误"
        }
    }

    func selectDifference(_ difference: JSONDifference) {
        selectedDifference = difference.id
        if let range = difference.leftRange {
            leftSelection = EditorSelection(range: range)
        }
        if let range = difference.rightRange {
            rightSelection = EditorSelection(range: range)
        }
    }

    func jumpToCodeNode(_ node: JSONOutlineNode, switchToCode: Bool) {
        if switchToCode {
            jsonViewMode = .code
        }
        inputSelection = EditorSelection(range: node.range)
    }

    func pasteFormattedJSON() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        draftEditor.replaceInput(JSONPaste.formatted(value) ?? value, actionName: "粘贴")
    }
}
