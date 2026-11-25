import AppKit
import DontsToolCore
import SwiftUI

struct ToolEditorPane<Actions: View>: View {
    let title: String
    @Binding var text: String
    var readOnly = false
    var json = false
    var wrap = true
    var folding = false
    var selection: EditorSelection?
    var foldCommand: EditorFoldCommand? = nil
    var diffLineKinds: [Int: JSONDifference.Kind] = [:]
    var statusDotColor: Color? = nil
    var subtitle: String? = nil
    var name: Binding<String>?
    var active = true
    var stale = false
    var editRevision = 0
    var undoManager: UndoManager?
    var onCursorChange: ((EditorCursorPosition) -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @State private var focused = false
    @State private var renaming = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let statusDotColor {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ToolTheme.ink)
                    .lineLimit(1)
                    .help(title)
                if let name {
                    Button { renaming = true } label: {
                        Image(systemName: "pencil").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ToolTheme.secondary)
                    .help("重命名这一侧")
                    .popover(isPresented: $renaming) {
                        ToolNameEditor(label: "内容名称", current: name.wrappedValue, onCancel: { renaming = false }) { value in
                            name.wrappedValue = value; renaming = false
                        }
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 0)
                actions().controlSize(.small)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(ToolTheme.toolbar)

            ToolTheme.border.frame(height: 0.5)

            ToolTextEditor(
                text: $text,
                readOnly: readOnly,
                json: json,
                wrap: wrap,
                folding: folding,
                selection: selection,
                foldCommand: foldCommand,
                diffLineKinds: diffLineKinds,
                active: active,
                editRevision: editRevision,
                sharedUndoManager: undoManager,
                label: title,
                onFocusChange: { focused = $0 },
                onCursorChange: onCursorChange
            )

            if stale {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text("旧结果已过期，请重新处理")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.warning.opacity(0.08))
            }
        }
        .frame(minWidth: 230, minHeight: 120)
        .background(ToolTheme.editor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? ToolTheme.accent.opacity(0.65) : ToolTheme.border, lineWidth: focused ? 1 : 0.5)
        )
        .padding(4)
    }
}

struct ToolNameEditor: View {
    let label: String
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var name: String
    @FocusState private var focus: Bool

    init(label: String, current: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.label = label; self.onCancel = onCancel; self.onSave = onSave; _name = State(initialValue: current)
    }

    private var trimmed: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.system(size: 13, weight: .semibold))
            TextField("输入名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focus)
                .onSubmit { save() }
                .accessibilityLabel(label)
            HStack {
                Text("最多 80 个字符").font(.system(size: 11)).foregroundStyle(ToolTheme.secondary)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(.borderedProminent).disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .tint(ToolTheme.accent)
        .onAppear { focus = true }
    }

    private func save() { if !trimmed.isEmpty { onSave(trimmed) } }
}
