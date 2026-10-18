import AppKit
import SwiftUI

struct ToolEditorPane<Actions: View>: View {
    let title: String
    @Binding var text: String
    var readOnly = false
    var json = false
    var wrap = true
    var selection: EditorSelection?
    var name: Binding<String>?
    var active = true
    var stale = false
    var editRevision = 0
    var undoManager: UndoManager?
    @ViewBuilder var actions: () -> Actions
    @State private var focused = false
    @State private var renaming = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(ToolTheme.ink).lineLimit(1).help(title)
                if let name {
                    Button { renaming = true } label: { Image(systemName: "pencil").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(ToolTheme.secondary).help("重命名这一侧")
                        .popover(isPresented: $renaming) {
                            ToolNameEditor(label: "内容名称", current: name.wrappedValue, onCancel: { renaming = false }) { value in
                                name.wrappedValue = value; renaming = false
                            }
                        }
                }
                Spacer(minLength: 0)
                actions().controlSize(.small)
            }.padding(.horizontal, 10).frame(height: 36).background(ToolTheme.toolbar)
            Divider().overlay(ToolTheme.border)
            ToolTextEditor(text: $text, readOnly: readOnly, json: json, wrap: wrap, selection: selection, active: active, editRevision: editRevision, sharedUndoManager: undoManager, label: title, onFocusChange: { focused = $0 })
            if stale {
                HStack {
                    Label("旧结果已过期，请重新处理", systemImage: "exclamationmark.circle")
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).foregroundStyle(Theme.warning)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.warning.opacity(0.06))
            }
        }
        .frame(minWidth: 230, minHeight: 120).background(ToolTheme.editor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? ToolTheme.accent.opacity(0.7) : ToolTheme.border, lineWidth: 1))
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
        VStack(alignment: .leading, spacing: 14) {
            Text(label).font(.system(size: 13, weight: .semibold))
            TextField("输入名称", text: $name).textFieldStyle(.roundedBorder).focused($focus).onSubmit { save() }.accessibilityLabel(label)
            HStack { Text("最多 80 个字符").font(.system(size: 11)).foregroundStyle(ToolTheme.secondary); Spacer(); Button("取消", action: onCancel).keyboardShortcut(.cancelAction); Button("保存", action: save).buttonStyle(.borderedProminent).disabled(trimmed.isEmpty) }
        }.padding(18).frame(width: 320).tint(ToolTheme.accent).onAppear { focus = true }
    }
    private func save() { if !trimmed.isEmpty { onSave(trimmed) } }
}
