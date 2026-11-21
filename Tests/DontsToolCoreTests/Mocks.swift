import Foundation
@testable import DontsToolCore

@MainActor
final class MockProvider: ToolProvider {
    let id: String
    let displayName: String
    var keywords: [String]
    var priority: Int
    var isEnabled: Bool
    var phase: SearchPhase
    var statusNotice: String?
    var homeEntryItem: SearchItem?
    var searchHandler: (SearchContext) async -> [SearchItem]
    private(set) var receivedQueries: [String] = []

    init(
        id: String,
        displayName: String = "Mock",
        keywords: [String] = [],
        priority: Int = 0,
        isEnabled: Bool = true,
        phase: SearchPhase = .fast,
        statusNotice: String? = nil,
        homeEntryItem: SearchItem? = nil,
        searchHandler: @escaping (SearchContext) async -> [SearchItem] = { _ in [] }
    ) {
        self.id = id
        self.displayName = displayName
        self.keywords = keywords
        self.priority = priority
        self.isEnabled = isEnabled
        self.phase = phase
        self.statusNotice = statusNotice
        self.homeEntryItem = homeEntryItem
        self.searchHandler = searchHandler
    }

    func homeToolEntry() -> SearchItem? {
        isEnabled ? homeEntryItem : nil
    }

    func search(_ context: SearchContext) async -> [SearchItem] {
        receivedQueries.append(context.query)
        return await searchHandler(context)
    }
}

func makeItem(
    providerID: String = "mock",
    group: ResultGroup = .tool,
    title: String = "Item",
    score: Double = 0,
    canonicalKey: String = UUID().uuidString
) -> SearchItem {
    SearchItem(
        providerID: providerID,
        group: group,
        title: title,
        icon: .symbol(name: "circle", tint: .gray),
        score: score,
        canonicalKey: canonicalKey,
        actions: []
    )
}

@MainActor
final class MockClipboard: ClipboardProviding {
    var value: String?
    var written: [String] = []

    func readString() -> String? { value }

    func writeString(_ string: String) {
        value = string
        written.append(string)
    }
}

@MainActor
final class MockPrefiller: QueryPrefilling {
    var queries: [String] = []

    func prefill(_ query: String) {
        queries.append(query)
    }
}

final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func secret(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func setSecret(_ value: String?, for account: String) {
        lock.lock()
        defer { lock.unlock() }
        values[account] = value
    }
}

final class MockHTTPClient: HTTPRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var responseData: Data = Data("{}".utf8)
    var statusCode: Int = 200
    var error: Error?

    var requests: [URLRequest] {
        withLock { recorded }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        withLock { recorded.append(request) }
        if let error { throw error }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: "1.1",
            headerFields: nil
        )!
        return (responseData, response)
    }
}
