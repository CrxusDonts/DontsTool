import DontsToolCore
import SwiftUI

/// 便笺工作区左侧栏：搜索、置顶/最近分组、最近删除列表及快捷操作。
struct LocalNoteSidebarView: View {
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
                                LocalNoteSidebarRow(
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
        LocalNoteSidebarRow(note: note, isSelected: !state.showingTrash && note.id == activeNoteID) {
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

/// 侧边栏单条便笺行：展示标题、相对更新时间与摘要预览。
private struct LocalNoteSidebarRow: View {
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
