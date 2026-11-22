import Foundation

public enum CloudSyncError: LocalizedError, Equatable {
    case unauthorized
    case conflict(String)
    case revisionConflict(conflicts: [SyncRevisionConflict], message: String)
    case payloadTooLarge
    case serverError(statusCode: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "同步认证失败，请检查同步密钥（Sync Token）是否正确。"
        case .conflict(let message):
            "同步数据依赖异常：\(message)"
        case .revisionConflict(_, let message):
            message.isEmpty ? "同步版本已过期，存在远端更新冲突。" : "同步版本冲突：\(message)"
        case .payloadTooLarge:
            "单条同步内容超出大小限制（最大 20 MB）。"
        case .serverError(let statusCode, let message):
            message.isEmpty ? "同步服务返回错误（HTTP \(statusCode)）。" : "同步服务错误（HTTP \(statusCode)）：\(message)"
        case .invalidResponse:
            "同步服务返回了无法识别的响应格式。"
        }
    }
}

public struct CloudSyncClient: Sendable {
    public static let inlinePayloadLimit = 65_536

    public let origin: CloudSyncOrigin
    public let token: String
    private let httpClient: any HTTPRequesting

    public init(origin: CloudSyncOrigin, token: String, httpClient: any HTTPRequesting = URLSessionHTTPClient()) {
        self.origin = origin
        self.token = token
        self.httpClient = httpClient
    }

    public func health() async throws -> SyncHealthResponse {
        let request = makeRequest(url: origin.endpointURL("v1/health"), method: "GET", timeout: 15)
        let data = try await perform(request)
        return try decode(SyncHealthResponse.self, from: data)
    }

    public func checkMissingBlobs(_ hashes: [String]) async throws -> [String] {
        guard !hashes.isEmpty else { return [] }
        var request = makeRequest(url: origin.endpointURL("v1/blobs/check"), method: "POST", timeout: 20)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try SyncJSON.makeEncoder().encode(SyncBlobsCheckRequest(hashes: hashes))
        let data = try await perform(request)
        return try decode(SyncBlobsCheckResponse.self, from: data).missing
    }

    public func uploadBlob(sha256: String, data: Data) async throws {
        var request = makeRequest(url: origin.endpointURL("v1/blobs/\(sha256)"), method: "PUT", timeout: 120)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await perform(request)
    }

    public func downloadBlob(sha256: String) async throws -> Data {
        let request = makeRequest(url: origin.endpointURL("v1/blobs/\(sha256)"), method: "GET", timeout: 120)
        let data = try await perform(request)
        guard SyncDigest.sha256Hex(data) == sha256 else {
            throw CloudSyncError.invalidResponse
        }
        return data
    }

    public func push(_ payload: SyncPushRequest) async throws -> SyncPushResponse {
        var request = makeRequest(url: origin.endpointURL("v1/sync/push"), method: "POST", timeout: 60)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try SyncJSON.makeEncoder().encode(payload)
        let data = try await perform(request)
        return try decode(SyncPushResponse.self, from: data)
    }

    public func pull(since: Int64, limit: Int = 100) async throws -> SyncPullResponse {
        let url = origin.endpointURL("v1/sync/pull", queryItems: [
            URLQueryItem(name: "since", value: String(max(0, since))),
            URLQueryItem(name: "limit", value: String(min(max(1, limit), 200)))
        ])
        let request = makeRequest(url: url, method: "GET", timeout: 30)
        let data = try await perform(request)
        return try decode(SyncPullResponse.self, from: data)
    }

    private func makeRequest(url: URL, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudSyncError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw CloudSyncError.unauthorized
        case 409:
            let errorEnvelope = try? SyncJSON.makeDecoder().decode(Sync409ResponseBody.self, from: data)
            let message = errorEnvelope?.error ?? serverMessage(from: data)
            if errorEnvelope?.code == "revision_conflict" {
                throw CloudSyncError.revisionConflict(
                    conflicts: errorEnvelope?.conflicts ?? [],
                    message: message
                )
            }
            throw CloudSyncError.conflict(message)
        case 413:
            throw CloudSyncError.payloadTooLarge
        default:
            throw CloudSyncError.serverError(statusCode: http.statusCode, message: serverMessage(from: data))
        }
    }

    private struct Sync409ResponseBody: Decodable {
        let error: String?
        let code: String?
        let conflicts: [SyncRevisionConflict]?
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try SyncJSON.makeDecoder().decode(T.self, from: data)
        } catch {
            throw CloudSyncError.invalidResponse
        }
    }

    private func serverMessage(from data: Data) -> String {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = dict["error"] as? String else {
            return ""
        }
        return message
    }
}

public protocol SyncRealtimeListening: AnyObject, Sendable {
    func start(onSyncEvent: @escaping @Sendable (Int64, String) -> Void, onConnectionChanged: @escaping @Sendable (Bool) -> Void)
    func stop()
}

public final class URLSessionSyncRealtimeClient: SyncRealtimeListening, @unchecked Sendable {
    private let origin: CloudSyncOrigin
    private let token: String
    private let lock = NSLock()
    private var loopTask: Task<Void, Never>?
    private var activeTask: URLSessionWebSocketTask?
    private var stopped = false

    public init(origin: CloudSyncOrigin, token: String) {
        self.origin = origin
        self.token = token
    }

    public func start(
        onSyncEvent: @escaping @Sendable (Int64, String) -> Void,
        onConnectionChanged: @escaping @Sendable (Bool) -> Void
    ) {
        stop()
        lock.lock()
        stopped = false
        loopTask = Task { [weak self] in
            await self?.runLoop(onSyncEvent: onSyncEvent, onConnectionChanged: onConnectionChanged)
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let task = loopTask
        let socket = activeTask
        loopTask = nil
        activeTask = nil
        lock.unlock()
        task?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private var isStopped: Bool {
        lock.withLock { stopped || Task.isCancelled }
    }

    private func registerActiveSocket(_ socket: URLSessionWebSocketTask) -> Bool {
        lock.withLock {
            if stopped { return false }
            activeTask = socket
            return true
        }
    }

    private func runLoop(
        onSyncEvent: @escaping @Sendable (Int64, String) -> Void,
        onConnectionChanged: @escaping @Sendable (Bool) -> Void
    ) async {
        var backoffSeconds: UInt64 = 2
        while !isStopped {
            var request = URLRequest(url: origin.webSocketURL(), timeoutInterval: 30)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            guard registerActiveSocket(socket) else {
                socket.cancel(with: .normalClosure, reason: nil)
                return
            }

            socket.resume()
            var connected = false
            let pingTask = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled else { break }
                        try await socket.send(.string("ping"))
                    } catch {
                        if !Task.isCancelled {
                            socket.cancel(with: .goingAway, reason: nil)
                        }
                        break
                    }
                }
            }

            do {
                while !isStopped {
                    let message = try await socket.receive()
                    if !connected {
                        connected = true
                        backoffSeconds = 2
                        onConnectionChanged(true)
                    }
                    if case .string(let text) = message, text != "pong",
                       let data = text.data(using: .utf8),
                       let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data),
                       let revision = event.revision {
                        onSyncEvent(revision, event.sourceDeviceId ?? "")
                    }
                }
            } catch {
                // Connection dropped; fall through to exponential backoff reconnect.
            }

            pingTask.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            onConnectionChanged(false)
            guard !isStopped else { return }
            let statusCode = (socket.response as? HTTPURLResponse)?.statusCode
            let isAuthFailure = statusCode == 401 || statusCode == 403
            let delaySeconds: UInt64 = isAuthFailure ? 300 : backoffSeconds
            try? await Task.sleep(for: .seconds(delaySeconds))
            backoffSeconds = isAuthFailure ? 300 : min(backoffSeconds * 2, 60)
        }
    }

    private struct RealtimeEvent: Decodable {
        let type: String
        let revision: Int64?
        let sourceDeviceId: String?
    }
}
