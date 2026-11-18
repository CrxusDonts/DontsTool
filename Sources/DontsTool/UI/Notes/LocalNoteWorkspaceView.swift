import DontsToolCore
import SwiftUI

/// 本地便笺主工作区容器：组合侧边栏列表与右侧编辑器面板。
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
                LocalNoteSidebarView(
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

            LocalNoteEditorPaneView(
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
