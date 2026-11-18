import DontsToolCore
import SwiftUI

extension ToolWorkspaceView {
    // Keep both native editor sets alive so mode switches preserve selection and undo targets.
    var jsonBody: some View {
        ZStack {
            jsonComparisonBody.opacity(session.comparing ? 1 : 0).allowsHitTesting(session.comparing).accessibilityHidden(!session.comparing)
            jsonEditBody.opacity(session.comparing ? 0 : 1).allowsHitTesting(!session.comparing).accessibilityHidden(session.comparing)
        }
    }

    private var jsonComparisonBody: some View {
        VSplitView {
            HSplitView {
                ToolEditorPane(
                    title: document.leftTitle,
                    text: $session.compareLeft,
                    json: true,
                    wrap: wrap,
                    selection: leftSelection,
                    name: $document.leftTitle,
                    active: session.comparing,
                    editRevision: draftEditor.revision,
                    undoManager: draftEditor.undoManager
                ) {
                    Button("粘贴") { paste(into: &session.compareLeft) }
                    Button("清空") { session.compareLeft = "" }
                }
                ToolEditorPane(
                    title: document.rightTitle,
                    text: $session.compareRight,
                    json: true,
                    wrap: wrap,
                    selection: rightSelection,
                    name: $document.rightTitle,
                    active: session.comparing,
                    editRevision: draftEditor.revision,
                    undoManager: draftEditor.undoManager
                ) {
                    Button("粘贴") { paste(into: &session.compareRight) }
                    Button("清空") { session.compareRight = "" }
                }
            }
            .frame(minHeight: 200)

            differences
                .frame(minHeight: 130, idealHeight: 200)
                .background(ToolTheme.editor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ToolTheme.border, lineWidth: 0.5))
                .padding(4)
        }
    }

    private var jsonEditBody: some View { textEditorBody }

    private var differences: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("结构差异").fontWeight(.semibold)
                Spacer()
                Text(session.comparison.map { "\($0.total) 项" } ?? "尚未对比").foregroundStyle(ToolTheme.secondary)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(ToolTheme.toolbar)

            ToolTheme.border.frame(height: 0.5)

            if session.comparison != nil && session.hasStaleResult {
                Text("旧对比结果已过期，请重新对比")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }

            if let comparison = session.comparison {
                if comparison.total == 0 {
                    Text("无结构差异").foregroundStyle(ToolTheme.secondary).padding(16)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(comparison.differences) { difference in
                            Button {
                                selectedDifference = difference.id
                                if let range = difference.leftRange { leftSelection = EditorSelection(range: range) }
                                if let range = difference.rightRange { rightSelection = EditorSelection(range: range) }
                            } label: {
                                HStack(spacing: 12) {
                                    Text(difference.kind.rawValue)
                                        .foregroundStyle(difference.kind == .added ? Theme.success : difference.kind == .removed ? Theme.warning : ToolTheme.accent)
                                        .frame(width: 36)
                                    Text(difference.path).frame(width: 180, alignment: .leading)
                                    Text(difference.left).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right").foregroundStyle(Theme.tertiary)
                                    Text(difference.right).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(selectedDifference == difference.id ? ToolTheme.selection : Color.clear)
                            .disabled(!session.isFresh)

                            ToolTheme.border.frame(height: 0.5)
                        }
                    }
                }
            } else {
                Text("编辑两侧 JSON 后点击「对比」。对象忽略字段顺序，数组按索引比较。")
                    .font(.system(size: 12))
                    .foregroundStyle(ToolTheme.secondary)
                    .padding(16)
            }
            Spacer(minLength: 0)
        }
    }
}
