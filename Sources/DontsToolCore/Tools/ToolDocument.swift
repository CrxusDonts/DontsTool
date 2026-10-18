import Combine
import Foundation

/// A named tool draft. Identity and presentation labels are independent of operation state.
@MainActor
public final class ToolDocument: ObservableObject, Identifiable {
    public let id: UUID
    public let session: ToolSession
    public var kind: ToolKind { session.kind }
    @Published public var title: String
    @Published public var leftTitle = "左侧 JSON"
    @Published public var rightTitle = "右侧 JSON"
    @Published public var isPinned = false
    @Published public internal(set) var isClosed = false

    init(session: ToolSession, title: String) {
        id = UUID()
        self.session = session
        self.title = title
    }
}
