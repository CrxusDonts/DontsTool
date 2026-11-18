import AppKit
import DontsToolCore
import SwiftUI
@preconcurrency import WebKit

struct LocalNoteWorkspaceView: View {
    @ObservedObject var state: LocalNoteWindowState
    @ObservedObject var store: LocalNoteStore
    let onSelect: (UUID) -> Void
    let onCreateInWorkspace: () -> Void
    let onNewWindow: () -> Void
    let onToggleSidebar: () -> Void
    let onExport: () -> Void
    let onTrash: (UUID) -> Void
    let onRestore: (UUID) -> Void
    let onDeletePermanently: (UUID) -> Void
    let onEmptyTrash: () -> Void
    let onOpenWindow: (UUID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if state.isSidebarVisible {
                NoteSidebarView(
                    state: state,
                    store: store,
                    activeNoteID: state.session.record.id,
                    onSelect: onSelect,
                    onCreateInWorkspace: onCreateInWorkspace,
                    onToggleSidebar: onToggleSidebar,
                    onTrash: onTrash,
                    onRestore: onRestore,
                    onDeletePermanently: onDeletePermanently,
                    onEmptyTrash: onEmptyTrash,
                    onOpenWindow: onOpenWindow
                )
                .frame(width: 220)
                ToolTheme.border.frame(width: 0.5)
            }

            NoteEditorPaneView(
                state: state,
                session: state.session,
                store: store,
                onCreateInWorkspace: onCreateInWorkspace,
                onNewWindow: onNewWindow,
                onToggleSidebar: onToggleSidebar,
                onExport: onExport,
                onTrash: onTrash,
                onRestore: onRestore,
                onDeletePermanently: onDeletePermanently
            )
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(ToolTheme.ink)
        .background(ToolTheme.editor)
    }
}

private struct NoteSidebarView: View {
    @ObservedObject var state: LocalNoteWindowState
    @ObservedObject var store: LocalNoteStore
    let activeNoteID: UUID
    let onSelect: (UUID) -> Void
    let onCreateInWorkspace: () -> Void
    let onToggleSidebar: () -> Void
    let onTrash: (UUID) -> Void
    let onRestore: (UUID) -> Void
    let onDeletePermanently: (UUID) -> Void
    let onEmptyTrash: () -> Void
    let onOpenWindow: (UUID) -> Void

    private var filteredNotes: [LocalNoteRecord] {
        store.search(state.sidebarQuery, limit: 200)
    }

    private var pinnedNotes: [LocalNoteRecord] {
        filteredNotes.filter(\.isPinned)
    }

    private var recentNotes: [LocalNoteRecord] {
        filteredNotes.filter { !$0.isPinned }
    }

    private var filteredTrashedNotes: [LocalNoteRecord] {
        let query = state.sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.trashedNotes }
        return store.trashedNotes.filter {
            $0.title.localizedStandardContains(query) || $0.content.plainText.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 70, height: 1)
                Spacer(minLength: 4)
                Button(action: onCreateInWorkspace) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("新建便笺")
                .accessibilityLabel("新建便笺")

                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("收起侧栏 ⌘\\")
                .accessibilityLabel("收起侧栏")
            }
            .buttonStyle(.plain)
            .foregroundStyle(ToolTheme.secondary)
            .padding(.trailing, 10)
            .frame(height: 40)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                TextField(state.showingTrash ? "搜索最近删除…" : "搜索便笺…", text: $state.sidebarQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !state.sidebarQuery.isEmpty {
                    Button { state.sidebarQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ToolTheme.border, lineWidth: 0.5))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            ToolTheme.border.frame(height: 0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if state.showingTrash {
                        HStack {
                            Text("最近删除")
                                .font(Theme.groupCaptionFont)
                                .foregroundStyle(Theme.tertiary)
                            Spacer()
                            Button("返回") {
                                state.showingTrash = false
                                state.previewingTrashedID = nil
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ToolTheme.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        if filteredTrashedNotes.isEmpty {
                            Text(store.trashedNotes.isEmpty ? "没有已删除的便笺" : "没有匹配的已删除便笺")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 16)
                        } else {
                            ForEach(filteredTrashedNotes) { note in
                                NoteSidebarRow(
                                    note: note,
                                    isSelected: state.previewingTrashedID == note.id
                                ) {
                                    state.previewingTrashedID = note.id
                                }
                                .contextMenu {
                                    Button("恢复便笺") { onRestore(note.id) }
                                    Button("彻底删除", role: .destructive) { onDeletePermanently(note.id) }
                                }
                            }
                        }
                    } else {
                        if !pinnedNotes.isEmpty {
                            sidebarSectionCaption("置顶")
                            ForEach(pinnedNotes) { note in
                                activeNoteRow(note)
                            }
                        }
                        if !recentNotes.isEmpty {
                            sidebarSectionCaption(pinnedNotes.isEmpty ? "全部便笺" : "最近")
                            ForEach(recentNotes) { note in
                                activeNoteRow(note)
                            }
                        }
                        if filteredNotes.isEmpty {
                            Text("没有匹配的便笺")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 16)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)

            ToolTheme.border.frame(height: 0.5)

            HStack(spacing: 6) {
                Button {
                    state.showingTrash.toggle()
                    if state.showingTrash {
                        state.previewingTrashedID = store.trashedNotes.first?.id
                    } else {
                        state.previewingTrashedID = nil
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: state.showingTrash ? "tray.full" : "trash")
                            .font(.system(size: 11))
                        Text("最近删除")
                            .font(.system(size: 11.5, weight: state.showingTrash ? .medium : .regular))
                        if !store.trashedNotes.isEmpty {
                            Text("\(store.trashedNotes.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.controlFill, in: Capsule())
                        }
                    }
                    .foregroundStyle(state.showingTrash ? ToolTheme.ink : ToolTheme.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if state.showingTrash && !store.trashedNotes.isEmpty {
                    Button("清空", role: .destructive, action: onEmptyTrash)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .background(ToolTheme.shell)
    }

    private func sidebarSectionCaption(_ title: String) -> some View {
        Text(title)
            .font(Theme.groupCaptionFont)
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func activeNoteRow(_ note: LocalNoteRecord) -> some View {
        NoteSidebarRow(note: note, isSelected: !state.showingTrash && note.id == activeNoteID) {
            onSelect(note.id)
        }
        .contextMenu {
            Button(note.isPinned ? "取消列表置顶" : "列表置顶") {
                _ = try? store.setPinned(note.id, pinned: !note.isPinned)
            }
            Button("在新窗口打开") { onOpenWindow(note.id) }
            Divider()
            Button("移入最近删除", role: .destructive) { onTrash(note.id) }
        }
    }
}

private struct NoteSidebarRow: View {
    let note: LocalNoteRecord
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var previewText: String {
        let lines = note.content.plainText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if note.titleIsAutomatic, lines.count > 1 {
            return lines[1]
        }
        if let first = lines.first, first != note.title {
            return first
        }
        return lines.dropFirst().first ?? "空白便笺"
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(note.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(ToolTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(relativeTime(note.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
                Text(previewText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Theme.selection : (isHovered ? Theme.rowHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Theme.selectionBorder : Color.clear, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if Calendar.current.isDateInToday(date) { return "\(Int(seconds / 3600)) 小时前" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", components.month ?? 1, components.day ?? 1)
    }
}

private struct NoteEditorPaneView: View {
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

private struct LocalNoteEditorView: NSViewRepresentable {
    let bridge: LocalNoteEditorBridge
    let appearance: String
    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ view: WKWebView, context: Context) { bridge.setAppearance(appearance) }
}
