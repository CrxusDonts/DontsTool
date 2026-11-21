import Foundation

/// 网络抽象：翻译与 AI 服务只依赖它，测试可注入假实现。
public protocol HTTPRequesting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// 流式网络抽象：用于 SSE 逐块流式响应，支持任务取消。
public protocol HTTPStreaming: HTTPRequesting {
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse)
}

public struct URLSessionHTTPClient: HTTPStreaming {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let box = UncheckedBytesBox(bytes: bytes)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(1024)
                    for try await byte in box.bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if byte == 0x0A || buffer.count >= 512 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return (stream, response)
    }
}

private final class UncheckedBytesBox: @unchecked Sendable {
    let bytes: URLSession.AsyncBytes

    init(bytes: URLSession.AsyncBytes) {
        self.bytes = bytes
    }
}
