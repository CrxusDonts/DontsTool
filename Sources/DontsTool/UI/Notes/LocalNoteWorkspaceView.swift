import AppKit
import DontsToolCore
import SwiftUI
@preconcurrency import WebKit

struct LocalNoteWorkspaceView: View {
    @ObservedObject var session: LocalNoteSession
    @ObservedObject var store: LocalNoteStore
    let onNew: () -> Void
    let onRename: () -> Void
    let onExport: () -> Void
    let onRestore: (UUID) -> Void
    let onOpen: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "note.text").foregroundStyle(ToolTheme.secondary)
                Button(action: onRename) { Text(session.record.title).lineLimit(1).font(.system(size: 13, weight: .medium)) }
                    .buttonStyle(.plain).help("命名便笺")
                Spacer(minLength: 12)
                Button(action: onNew) { Image(systemName: "square.and.pencil") }.help("新建便笺 ⌘N")
                Button { session.togglePin() } label: { Image(systemName: session.record.isPinned ? "pin.fill" : "pin") }.help("窗口置顶")
                    .disabled(session.isTrashed)
                Menu {
                    Menu("打开便笺") {
                        ForEach(store.notes) { note in Button(note.title) { onOpen(note.id) } }
                    }
                    Divider()
                    Button("命名…", action: onRename).disabled(session.isTrashed)
                    Button("导出 Markdown 与图片…", action: onExport).disabled(session.isTrashed)
                    Divider()
                    Button("移入最近删除", role: .destructive) { Task { _ = await session.trash() } }.disabled(session.isTrashed)
                    Menu("最近删除") {
                        if store.trashedNotes.isEmpty { Text("没有已删除的便笺") }
                        ForEach(store.trashedNotes) { note in Button(note.title) { onRestore(note.id) } }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
            .buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 42).background(ToolTheme.toolbar)
            Divider().overlay(ToolTheme.border)
            ZStack {
                LocalNoteEditorView(bridge: session.bridge, appearance: colorScheme == .dark ? "dark" : "light")
                if session.isTrashed {
                    VStack(spacing: 14) {
                        Image(systemName: "trash").font(.system(size: 28)).foregroundStyle(ToolTheme.secondary)
                        Text("便笺已移入最近删除").font(.headline)
                        Text("正文和图片仍保存在本机，可以恢复。").foregroundStyle(ToolTheme.secondary)
                        Button("恢复便笺") { session.restore() }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ToolTheme.editor)
                }
                LocalNoteEditorStateView(bridge: session.bridge, isTrashed: session.isTrashed)
            }
            if let error = session.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("重试") { Task { await session.retry() } }
                }.padding(12).background(ToolTheme.toolbar)
            }
            Divider().overlay(ToolTheme.border)
            HStack(spacing: 6) {
                Image(systemName: session.errorMessage == nil ? "checkmark.circle" : "exclamationmark.circle")
                Text(session.status)
                Spacer()
                Text("\(session.draft.plainText.count) 字符")
                Text("· 本地便笺")
            }.font(.system(size: 11)).foregroundStyle(ToolTheme.secondary).padding(.horizontal, 18).frame(height: 30).background(ToolTheme.toolbar)
        }.foregroundStyle(ToolTheme.ink).background(ToolTheme.editor)
    }
}

private struct LocalNoteEditorStateView: View {
    @ObservedObject var bridge: LocalNoteEditorBridge
    let isTrashed: Bool
    var body: some View {
        if !isTrashed {
            switch bridge.state {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(ToolTheme.editor)
            case .failed(let message):
                VStack(spacing: 14) { Text(message); Button("重新加载编辑器") { bridge.reload() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(ToolTheme.editor)
            case .ready: EmptyView()
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
