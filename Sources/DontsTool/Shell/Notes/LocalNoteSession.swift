import Combine
import DontsToolCore
import Foundation

@MainActor
final class LocalNoteSession: ObservableObject {
    @Published private(set) var record: LocalNoteRecord
    @Published private(set) var status = "已保存在本机"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTrashed = false
    private(set) var draft: LocalNoteContent
    let store: LocalNoteStore
    let bridge: LocalNoteEditorBridge
    private var editorIssue: String?
    private var autosave: Task<Void, Never>?
    private var metadataObservation: AnyCancellable?

    init(record: LocalNoteRecord, store: LocalNoteStore, resourcesURL: URL? = nil) {
        self.record = record; self.store = store; draft = record.content
        bridge = LocalNoteEditorBridge(note: record, store: store, resourcesURL: resourcesURL)
        bridge.onChange = { [weak self] value in self?.accept(value) }
        bridge.onError = { [weak self] message in
            self?.editorIssue = message; self?.errorMessage = message; self?.status = "待完成编辑"
        }
        metadataObservation = store.$notes.sink { [weak self] notes in
            guard let self, !self.isTrashed,
                  let latest = notes.first(where: { $0.id == self.record.id }),
                  latest.content == self.record.content,
                  latest != self.record else { return }
            self.record = latest
        }
    }

    func accept(_ content: LocalNoteContent) {
        guard !isTrashed else { return }
        draft = content; status = "保存中…"; errorMessage = nil; editorIssue = nil
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            _ = self.flush()
        }
    }

    @discardableResult func flush() -> Bool {
        autosave?.cancel(); autosave = nil
        guard !isTrashed else { return true }
        do {
            if draft != record.content { record = try store.updateContent(record.id, content: draft) }
            status = editorIssue == nil ? "已保存在本机" : "待完成编辑"; errorMessage = editorIssue
            return true
        } catch { fail(error.localizedDescription); return false }
    }

    func captureAndFlush(freeze: Bool = false) async -> Bool {
        guard !isTrashed else { return true }
        if freeze && !bridge.isEditable { return true }
        do {
            draft = try await bridge.snapshot(freeze: freeze)
            let saved = flush()
            if freeze && !saved { bridge.setEditable(true) }
            return saved
        } catch {
            if freeze { bridge.setEditable(true) }
            fail(error.localizedDescription); return false
        }
    }

    func syncExternalUpdate(_ updated: LocalNoteRecord) {
        guard !isTrashed else { return }
        autosave?.cancel(); autosave = nil
        record = updated
        draft = updated.content
        status = "已保存在本机"
        errorMessage = nil
        editorIssue = nil
        bridge.reloadContent(updated.content)
    }

    func rename(_ title: String) {
        guard flush(), !isTrashed else { return }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.titleIsAutomatic && normalized.isEmpty { return }
        if !record.titleIsAutomatic && normalized == record.title { return }
        do { record = try store.rename(record.id, title: title) }
        catch { fail(error.localizedDescription) }
    }

    func togglePin() {
        guard flush(), !isTrashed else { return }
        do { record = try store.setPinned(record.id, pinned: !record.isPinned) }
        catch { fail(error.localizedDescription) }
    }

    func trash() async -> Bool {
        guard await captureAndFlush(freeze: true) else { return false }
        do {
            try store.trash(record.id); autosave?.cancel(); isTrashed = true
            bridge.setEditable(false); status = "已移入最近删除"; return true
        } catch { bridge.setEditable(true); fail(error.localizedDescription); return false }
    }

    func restore() {
        do {
            record = try store.restore(record.id); draft = record.content; isTrashed = false
            bridge.setEditable(true); bridge.reload(); status = "已保存在本机"; errorMessage = nil
        } catch { fail(error.localizedDescription) }
    }

    func retry() async {
        if bridge.state != .ready { bridge.reload() }
        else { _ = await captureAndFlush() }
    }

    func fail(_ message: String) { status = "保存未完成"; errorMessage = message }
    func stop() { metadataObservation?.cancel(); autosave?.cancel(); bridge.stop() }
}
