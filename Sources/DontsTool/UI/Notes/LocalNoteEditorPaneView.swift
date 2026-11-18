import AppKit
import DontsToolCore
import SwiftUI
@preconcurrency import WebKit

/// 便笺右侧编辑面板：包含标题栏、编辑器画布、废纸篓预览、错误重试条与底栏。
struct LocalNoteEditorPaneView: View {
    @ObservedObject var state: LocalNoteWindowState
    @ObservedObject var session: LocalNoteSession
    @ObservedObject var store: LocalNoteStore
    let onCreateInWorkspace: () -> Void
    let onNewWindow: () -> Void
    let onToggleSidebar: () -> Void
    let onExport: () -> Void
    let onTrash: (UUID) -> Void
    let onRestore: (UUID) -> Void
    let onDeletePermanently: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    private var previewedTrashedNote: LocalNoteRecord? {
        guard state.showingTrash, let id = state.previewingTrashedID else { return nil }
        return store.trashedNotes.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            ToolTheme.border.frame(height: 0.5)

            if let trashed = previewedTrashedNote {
                trashedPreviewView(trashed)
            } else {
                ZStack {
                    LocalNoteEditorView(bridge: session.bridge, appearance: colorScheme == .dark ? "dark" : "light")
                        .id(session.record.id)
                    if session.isTrashed {
                        VStack(spacing: 12) {
                            Image(systemName: "trash").font(.system(size: 26)).foregroundStyle(ToolTheme.secondary)
                            Text("便笺已移入最近删除").font(.headline)
                            Text("正文和图片仍保存在本机，可以恢复。").font(.system(size: 12.5)).foregroundStyle(ToolTheme.secondary)
                            Button("恢复便笺") { session.restore() }.buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ToolTheme.editor)
                    }
                    LocalNoteEditorStateView(bridge: session.bridge, isTrashed: session.isTrashed)
                }

                if let error = session.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                        Text(error).font(.system(size: 12)).textSelection(.enabled)
                        Spacer()
                        Button("重试") { Task { await session.retry() } }.controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ToolTheme.toolbar)
                }
            }

            ToolTheme.border.frame(height: 0.5)
            footerBar
        }
        .background(ToolTheme.editor)
        .onAppear { titleDraft = session.record.title }
        .onChange(of: session.record.id) { _, _ in
            titleFocused = false
            titleDraft = session.record.title
        }
        .onChange(of: session.record.title) { _, newTitle in
            if !titleFocused {
                titleDraft = newTitle
            }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused {
                commitTitle()
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            if !state.isSidebarVisible {
                Color.clear.frame(width: 68, height: 1)
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13))
                        .foregroundStyle(ToolTheme.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("展开列表 ⌘\\")
                .accessibilityLabel("展开列表")
            }

            if let trashed = previewedTrashedNote {
                Text(trashed.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ToolTheme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            } else {
                TextField("未命名便笺", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ToolTheme.ink)
                    .focused($titleFocused)
                    .disabled(session.isTrashed)
                    .onSubmit {
                        commitTitle()
                        titleFocused = false
                    }
                    .accessibilityLabel("便笺标题")
                Spacer(minLength: 8)
            }

            if !state.isSidebarVisible {
                Button(action: onCreateInWorkspace) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(ToolTheme.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("新建便笺")
            }

            Button { state.isWindowFloating.toggle() } label: {
                Image(systemName: state.isWindowFloating ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(state.isWindowFloating ? ToolTheme.ink : ToolTheme.secondary)
                    .frame(width: 24, height: 24)
                    .background(state.isWindowFloating ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.isWindowFloating ? "取消窗口悬浮置顶" : "窗口悬浮置顶（保持在其他窗口前面）")
            .accessibilityLabel(state.isWindowFloating ? "取消窗口悬浮置顶" : "窗口悬浮置顶")

            Menu {
                Button(session.record.isPinned ? "取消列表置顶" : "列表置顶") { session.togglePin() }
                    .disabled(session.isTrashed)
                Button("在新窗口新建便笺 ⌘N", action: onNewWindow)
                Divider()
                Button("导出 Markdown 与图片…", action: onExport)
                    .disabled(session.isTrashed)
                Divider()
                Button("移入最近删除", role: .destructive) { onTrash(session.record.id) }
                    .disabled(session.isTrashed)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(ToolTheme.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(ToolTheme.toolbar)
    }

    private func trashedPreviewView(_ trashed: LocalNoteRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(ToolTheme.secondary)
                Text("位于最近删除，可恢复到便笺列表或彻底删除。")
                    .font(.system(size: 12))
                    .foregroundStyle(ToolTheme.secondary)
                Spacer()
                Button("彻底删除", role: .destructive) { onDeletePermanently(trashed.id) }
                    .controlSize(.small)
                Button("恢复便笺") { onRestore(trashed.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ToolTheme.shell)

            ToolTheme.border.frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(trashed.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(ToolTheme.ink)
                    Text(trashed.content.plainText.isEmpty ? "空白便笺" : trashed.content.plainText)
                        .font(.system(size: 13.5))
                        .foregroundStyle(ToolTheme.secondary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ToolTheme.editor)
        }
    }

    private var footerBar: some View {
        HStack(spacing: 6) {
            if let trashed = previewedTrashedNote {
                Text("最近删除预览")
                Spacer()
                Text("\(trashed.content.plainText.count) 字符")
            } else {
                Image(systemName: session.errorMessage == nil ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 10.5))
                Text(session.status)
                Spacer()
                Text("\(session.draft.plainText.count) 字符")
            }
            Text("·").foregroundStyle(Theme.tertiary)
            Button(action: onToggleSidebar) {
                Text(state.isSidebarVisible ? "⌘\\ 悬浮模式" : "⌘\\ 展开列表")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("\\", modifiers: .command)
        }
        .font(.system(size: 11))
        .foregroundStyle(ToolTheme.secondary)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(ToolTheme.shell)
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.record.titleIsAutomatic && trimmed == session.record.title { return }
        session.rename(titleDraft)
        if !titleFocused {
            titleDraft = session.record.title
        }
    }
}

/// 编辑器加载状态遮罩：展示加载进度与失败重载入口。
private struct LocalNoteEditorStateView: View {
    @ObservedObject var bridge: LocalNoteEditorBridge
    let isTrashed: Bool

    var body: some View {
        if !isTrashed {
            switch bridge.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ToolTheme.editor)
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message).font(.system(size: 13)).foregroundStyle(ToolTheme.secondary)
                    Button("重新加载编辑器") { bridge.reload() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToolTheme.editor)
            case .ready:
                EmptyView()
            }
        }
    }
}

/// 包装 WKWebView 的 SwiftUI 视图并同步外观主题。
private struct LocalNoteEditorView: NSViewRepresentable {
    let bridge: LocalNoteEditorBridge
    let appearance: String
    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ view: WKWebView, context: Context) { bridge.setAppearance(appearance) }
}
