import Combine
import Foundation

/// Documents live only for this application run. At most ten closed drafts are retained.
@MainActor
public final class ToolDocumentStore: ObservableObject {
    @Published public private(set) var documents: [ToolDocument] = []
    public var openDocuments: [ToolDocument] { documents.filter { !$0.isClosed } }
    public var recentlyClosed: [ToolDocument] {
        closedIDs.compactMap { id in documents.first { $0.id == id } }
    }
    private let translator: TranslationServicing?
    private let translationTarget: String
    private var counters: [ToolKind: Int] = [:]
    private var closedIDs: [UUID] = []
    private var observations: [UUID: AnyCancellable] = [:]

    public init(translator: TranslationServicing? = nil, translationTarget: String = "zh-Hans") {
        self.translator = translator
        self.translationTarget = translationTarget
    }

    @discardableResult
    public func create(_ request: ToolOpenRequest) -> ToolDocument {
        let session = ToolSession(kind: request.kind, translator: translator)
        if request.kind == .translation { session.target = translationTarget }
        session.accept(request)
        let number = (counters[request.kind] ?? 0) + 1
        counters[request.kind] = number
        let name: String
        switch request.kind {
        case .json: name = "JSON"
        case .base64: name = "Base64"
        case .url: name = "URL"
        case .timestamp: name = "时间戳"
        case .uuid: name = "UUID"
        case .hash: name = "哈希"
        case .translation: name = "翻译"
        }
        return insert(ToolDocument(session: session, title: "未命名 \(name) \(number)"))
    }

    @discardableResult
    public func duplicate(_ id: UUID) -> ToolDocument? {
        guard let source = document(id) else { return nil }
        let copy = ToolDocument(session: source.session.cloneDraft(), title: String(source.title.prefix(77)) + " 副本")
        copy.leftTitle = source.leftTitle
        copy.rightTitle = source.rightTitle
        return insert(copy)
    }

    public func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let document = document(id) else { return }
        document.title = String(title.prefix(80))
    }

    public func close(_ id: UUID) {
        guard let document = document(id), !document.isClosed else { return }
        document.session.cancel()
        document.isClosed = true
        closedIDs.insert(id, at: 0)
        while closedIDs.count > 10 {
            let evicted = closedIDs.removeLast()
            documents.removeAll { $0.id == evicted }
            observations.removeValue(forKey: evicted)
        }
        objectWillChange.send()
    }

    @discardableResult
    public func reopen(_ id: UUID) -> ToolDocument? {
        guard let document = document(id) else { return nil }
        document.isClosed = false
        closedIDs.removeAll { $0 == id }
        activate(id)
        return document
    }

    /// Open documents are ordered by most recent activation. Closed drafts keep their close order.
    public func activate(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id && !$0.isClosed }) else { return }
        let document = documents.remove(at: index)
        documents.insert(document, at: 0)
    }

    private func document(_ id: UUID) -> ToolDocument? { documents.first { $0.id == id } }
    private func insert(_ document: ToolDocument) -> ToolDocument {
        observations[document.id] = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        documents.insert(document, at: 0)
        return document
    }
}
