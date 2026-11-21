import Foundation

@MainActor
public protocol AIChatServicing: AnyObject {
    var isConfigured: Bool { get }
    var activeModelDisplay: String { get }
    var activeFormat: AIAPIFormat { get }
    var activeProfileName: String? { get }

    func complete(messages: [AIChatMessage], systemPrompt: String?) async throws -> String
    func stream(messages: [AIChatMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error>
}

public extension AIChatServicing {
    var activeProfileName: String? { nil }

    func complete(messages: [AIChatMessage]) async throws -> String {
        try await complete(messages: messages, systemPrompt: nil)
    }

    func stream(messages: [AIChatMessage]) -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, systemPrompt: nil)
    }
}

/// 统一大模型客户端：支持 OpenAI Responses、Gemini 原生 REST API 与 OpenAI Chat Completions。
/// 复用宿主「模型服务」多配置，按场景解析模型与密钥，密钥仅保存在宿主钥匙串，永不经过外部插件进程。
@MainActor
public final class RemoteAIChatService: AIChatServicing {
    private let settings: SettingsStore
    private let secrets: SecretStoring
    private let http: HTTPRequesting
    private let timeout: Duration
    public let purpose: AIUsagePurpose

    public init(
        settings: SettingsStore,
        secrets: SecretStoring,
        http: HTTPRequesting = URLSessionHTTPClient(),
        timeout: Duration = .seconds(60),
        purpose: AIUsagePurpose = .quickAI
    ) {
        self.settings = settings
        self.secrets = secrets
        self.http = http
        self.timeout = timeout
        self.purpose = purpose
    }

    public var isConfigured: Bool {
        let config = settings.resolvedAIConfiguration(for: purpose)
        return config.isEndpointComplete && settings.apiKey(for: config, secrets: secrets) != nil
    }

    public var activeFormat: AIAPIFormat {
        settings.resolvedAIConfiguration(for: purpose).format
    }

    public var activeProfileName: String? {
        settings.resolvedAIConfiguration(for: purpose).profileName
    }

    public var activeModelDisplay: String {
        settings.resolvedAIConfiguration(for: purpose).displaySummary
    }

    public func complete(messages: [AIChatMessage], systemPrompt: String? = nil) async throws -> String {
        let snapshot = try captureConfiguration(messages: messages)
        let request = try Self.makeRequest(
            config: snapshot,
            messages: messages,
            systemPrompt: systemPrompt,
            stream: false
        )
        let (data, response) = try await http.data(for: request)
        return try Self.parseNonStream(data: data, response: response, format: snapshot.format)
    }

    /// 直接测试模型表单草稿或已保存配置的连通性，返回请求往返耗时（秒）。
    public func testConnection(for profile: AIModelProfile, apiKey: String) async throws -> TimeInterval {
        let trimmedBase = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBase.isEmpty else {
            throw AIChatError.invalidEndpoint("请先填写接口地址")
        }
        guard !trimmedModel.isEmpty else {
            throw AIChatError.invalidEndpoint("请先填写模型名称")
        }
        guard !trimmedKey.isEmpty else {
            throw AIChatError.missingAPIKey
        }

        let probeTimeout = min(max(TimeInterval(timeout.components.seconds), 5), 20)
        let config = RequestConfiguration(
            format: profile.format,
            baseURL: trimmedBase,
            model: trimmedModel,
            apiKey: trimmedKey,
            timeoutSeconds: probeTimeout
        )
        let request = try Self.makeRequest(
            config: config,
            messages: [AIChatMessage(role: .user, content: "Reply with OK")],
            systemPrompt: "Reply with OK only.",
            stream: false
        )

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await http.data(for: request)
        _ = try Self.parseNonStream(data: data, response: response, format: config.format)
        let elapsed = start.duration(to: clock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    public func stream(messages: [AIChatMessage], systemPrompt: String? = nil) -> AsyncThrowingStream<String, Error> {
        let preparation: Result<(config: RequestConfiguration, request: URLRequest), Error>
        do {
            let config = try captureConfiguration(messages: messages)
            let request = try Self.makeRequest(
                config: config,
                messages: messages,
                systemPrompt: systemPrompt,
                stream: true
            )
            preparation = .success((config: config, request: request))
        } catch {
            preparation = .failure(error)
        }

        let httpClient = self.http
        return AsyncThrowingStream<String, Error> { continuation in
            switch preparation {
            case .failure(let error):
                continuation.finish(throwing: error)
                return
            case .success(let prepared):
                let task = Task {
                    do {
                        try await Self.runStream(
                            http: httpClient,
                            request: prepared.request,
                            format: prepared.config.format,
                            continuation: continuation
                        )
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
        }
    }

    // MARK: - Configuration Snapshot

    private struct RequestConfiguration: Sendable {
        let format: AIAPIFormat
        let baseURL: String
        let model: String
        let apiKey: String
        let timeoutSeconds: TimeInterval
    }

    private func captureConfiguration(messages: [AIChatMessage]) throws -> RequestConfiguration {
        let resolved = settings.resolvedAIConfiguration(for: purpose)
        guard resolved.isEndpointComplete else {
            throw AIChatError.notConfigured
        }
        guard let apiKey = settings.apiKey(for: resolved, secrets: secrets), !apiKey.isEmpty else {
            throw AIChatError.notConfigured
        }
        let hasContent = messages.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasContent else {
            throw AIChatError.emptyInput
        }
        return RequestConfiguration(
            format: resolved.format,
            baseURL: resolved.baseURL,
            model: resolved.model,
            apiKey: apiKey,
            timeoutSeconds: TimeInterval(timeout.components.seconds)
        )
    }

    // MARK: - Request Construction

    private nonisolated static func makeRequest(
        config: RequestConfiguration,
        messages: [AIChatMessage],
        systemPrompt: String?,
        stream: Bool
    ) throws -> URLRequest {
        let url = try resolveEndpointURL(
            baseURL: config.baseURL,
            model: config.model,
            format: config.format,
            stream: stream
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        let normalizedSystem = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSystem = (normalizedSystem?.isEmpty == false) ? normalizedSystem : nil

        let bodyObject: [String: Any]
        switch config.format {
        case .openAIResponses:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            var body: [String: Any] = ["model": config.model]
            if let effectiveSystem {
                body["instructions"] = effectiveSystem
            }
            if messages.count == 1, messages[0].role == .user {
                body["input"] = messages[0].content
            } else {
                body["input"] = messages.map { message in
                    ["role": message.role.rawValue, "content": message.content]
                }
            }
            if stream {
                body["stream"] = true
            }
            bodyObject = body

        case .gemini:
            // Gemini 鉴权严格走 HTTP Header，禁止拼入 URL Query。
            request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
            var body: [String: Any] = [
                "contents": messages.map { message in
                    [
                        "role": message.role == .assistant ? "model" : "user",
                        "parts": [["text": message.content]]
                    ] as [String: Any]
                }
            ]
            if let effectiveSystem {
                body["systemInstruction"] = [
                    "parts": [["text": effectiveSystem]]
                ]
            }
            bodyObject = body

        case .openAIChatCompletions:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            var chatMessages: [[String: String]] = []
            if let effectiveSystem {
                chatMessages.append(["role": "system", "content": effectiveSystem])
            }
            for message in messages {
                chatMessages.append(["role": message.role.rawValue, "content": message.content])
            }
            var body: [String: Any] = [
                "model": config.model,
                "messages": chatMessages
            ]
            if stream {
                body["stream"] = true
            }
            bodyObject = body
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObject, options: [])
        return request
    }

    private nonisolated static let geminiModelAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    nonisolated static func resolveEndpointURL(
        baseURL: String,
        model: String,
        format: AIAPIFormat,
        stream: Bool
    ) throws -> URL {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = trimmedBase.contains("://") ? trimmedBase : "https://\(trimmedBase)"
        guard var components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else {
            throw AIChatError.invalidEndpoint("API 地址无效，请填写 HTTP 或 HTTPS 接口地址")
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }

        switch format {
        case .openAIResponses:
            if !path.hasSuffix("/responses") {
                path += "/responses"
            }
            components.percentEncodedPath = path

        case .openAIChatCompletions:
            if !path.hasSuffix("/chat/completions") {
                path += "/chat/completions"
            }
            components.percentEncodedPath = path

        case .gemini:
            var normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedModel.hasPrefix("models/") {
                normalizedModel = String(normalizedModel.dropFirst("models/".count))
            }
            guard !normalizedModel.isEmpty,
                  let encodedModel = normalizedModel.addingPercentEncoding(withAllowedCharacters: geminiModelAllowedCharacters) else {
                throw AIChatError.invalidEndpoint("Gemini 模型名称无效")
            }

            let targetAction = stream ? ":streamGenerateContent" : ":generateContent"
            if path.hasSuffix(":generateContent") {
                path = String(path.dropLast(":generateContent".count)) + targetAction
            } else if path.hasSuffix(":streamGenerateContent") {
                path = String(path.dropLast(":streamGenerateContent".count)) + targetAction
            } else if path.isEmpty {
                path = "/v1beta/models/\(encodedModel)\(targetAction)"
            } else if path.hasSuffix("/models") {
                path += "/\(encodedModel)\(targetAction)"
            } else {
                path += "/models/\(encodedModel)\(targetAction)"
            }
            components.percentEncodedPath = path

            var queryItems = components.queryItems ?? []
            if stream {
                queryItems.removeAll { $0.name == "alt" }
                queryItems.append(URLQueryItem(name: "alt", value: "sse"))
                components.queryItems = queryItems
            } else if !queryItems.isEmpty {
                queryItems.removeAll { $0.name == "alt" && $0.value?.lowercased() == "sse" }
                components.queryItems = queryItems.isEmpty ? nil : queryItems
            }
        }

        guard let url = components.url else {
            throw AIChatError.invalidEndpoint("API 地址无效")
        }
        return url
    }

    // MARK: - Streaming Execution

    private nonisolated static func runStream(
        http: HTTPRequesting,
        request: URLRequest,
        format: AIAPIFormat,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        if let streamingClient = http as? HTTPStreaming {
            let (chunkStream, response) = try await streamingClient.stream(for: request)
            try await processChunkStream(
                chunkStream: chunkStream,
                response: response,
                format: format,
                continuation: continuation
            )
        } else {
            let (data, response) = try await http.data(for: request)
            try Task.checkCancellation()
            let singleChunkStream = AsyncThrowingStream<Data, Error> { single in
                if !data.isEmpty {
                    single.yield(data)
                }
                single.finish()
            }
            try await processChunkStream(
                chunkStream: singleChunkStream,
                response: response,
                format: format,
                continuation: continuation
            )
        }
    }

    private nonisolated static func processChunkStream(
        chunkStream: AsyncThrowingStream<Data, Error>,
        response: URLResponse,
        format: AIAPIFormat,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        if !(200..<300).contains(statusCode) {
            var errorBody = Data()
            for try await chunk in chunkStream {
                try Task.checkCancellation()
                if errorBody.count < 262_144 {
                    errorBody.append(chunk)
                }
            }
            throw extractHTTPError(data: errorBody, statusCode: statusCode, format: format)
        }

        if contentType.contains("application/json") && !contentType.contains("text/event-stream") {
            var fullBody = Data()
            for try await chunk in chunkStream {
                try Task.checkCancellation()
                fullBody.append(chunk)
            }
            let text = try parseNonStream(data: fullBody, response: response, format: format)
            continuation.yield(text)
            return
        }

        var lineBuffer = SSELineBuffer()
        var eventParser = SSEEventParser()
        var rawFallbackBuffer = Data()
        var streamState = StreamDecodeState()

        for try await chunk in chunkStream {
            try Task.checkCancellation()
            if !eventParser.sawSSE && rawFallbackBuffer.count < 2_097_152 {
                rawFallbackBuffer.append(chunk)
            }
            let lines = lineBuffer.append(chunk)
            for line in lines {
                let events = eventParser.consume(line: line)
                for eventPayload in events {
                    try handleSSEEvent(
                        eventPayload,
                        format: format,
                        state: &streamState,
                        continuation: continuation
                    )
                }
            }
            if eventParser.sawSSE && !rawFallbackBuffer.isEmpty {
                rawFallbackBuffer.removeAll(keepingCapacity: false)
            }
        }

        try Task.checkCancellation()

        if let trailingLine = lineBuffer.finish() {
            let events = eventParser.consume(line: trailingLine)
            for eventPayload in events {
                try handleSSEEvent(
                    eventPayload,
                    format: format,
                    state: &streamState,
                    continuation: continuation
                )
            }
        }
        for eventPayload in eventParser.finish() {
            try handleSSEEvent(
                eventPayload,
                format: format,
                state: &streamState,
                continuation: continuation
            )
        }

        if !eventParser.sawSSE && !rawFallbackBuffer.isEmpty {
            let text = try parseNonStream(data: rawFallbackBuffer, response: response, format: format)
            continuation.yield(text)
            return
        }

        if !streamState.didYieldText {
            if let blockedReason = streamState.blockedReason {
                throw AIChatError.blocked(blockedReason)
            }
            throw AIChatError.emptyResponse
        }
    }

    private struct StreamDecodeState {
        var didYieldText = false
        var blockedReason: String?
    }

    private nonisolated static func handleSSEEvent(
        _ payload: String,
        format: AIAPIFormat,
        state: inout StreamDecodeState,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[DONE]" else { return }
        let data = Data(trimmed.utf8)

        switch format {
        case .openAIResponses:
            guard let event = try? JSONDecoder().decode(OpenAIResponsesStreamEvent.self, from: data) else {
                return
            }
            if let message = event.error?.message, !message.isEmpty {
                throw AIChatError.apiError(message)
            }
            switch event.type {
            case "response.output_text.delta":
                if let delta = event.delta, !delta.isEmpty {
                    state.didYieldText = true
                    continuation.yield(delta)
                }
            case "response.failed", "error":
                let message = event.response?.error?.message
                    ?? event.error?.message
                    ?? event.message
                    ?? "模型服务处理失败"
                throw AIChatError.apiError(message)
            case "response.incomplete":
                let reason = event.response?.incomplete_details?.reason.map { "（\($0)）" } ?? ""
                throw AIChatError.incompleteResponse("模型服务响应未完成：incomplete\(reason)，请重试")
            case "response.completed":
                if !state.didYieldText, let response = event.response {
                    let fallback = response.output_text ?? joinedResponsesOutputText(response)
                    if !fallback.isEmpty {
                        state.didYieldText = true
                        continuation.yield(fallback)
                    }
                }
            default:
                if event.type == nil, let delta = event.delta, !delta.isEmpty {
                    state.didYieldText = true
                    continuation.yield(delta)
                }
            }

        case .gemini:
            let envelopes = decodeGeminiEnvelopes(from: data)
            for envelope in envelopes {
                if let message = envelope.error?.message, !message.isEmpty {
                    throw AIChatError.apiError(message)
                }
                if let blockReason = envelope.promptFeedback?.blockReason, !blockReason.isEmpty {
                    state.blockedReason = blockReason
                }
                if let candidate = envelope.candidates?.first {
                    if let finishReason = candidate.finishReason, isGeminiBlockingFinishReason(finishReason) {
                        state.blockedReason = finishReason
                    }
                    let visible = extractGeminiVisibleText(from: candidate)
                    if !visible.isEmpty {
                        state.didYieldText = true
                        continuation.yield(visible)
                    }
                }
            }

        case .openAIChatCompletions:
            guard let chunk = try? JSONDecoder().decode(OpenAIChatCompletionsStreamPayload.self, from: data) else {
                return
            }
            if let message = chunk.error?.message, !message.isEmpty {
                throw AIChatError.apiError(message)
            }
            if let choice = chunk.choices?.first {
                if choice.finish_reason == "content_filter" {
                    state.blockedReason = "content_filter"
                }
                if let delta = choice.delta?.content, !delta.isEmpty {
                    state.didYieldText = true
                    continuation.yield(delta)
                }
            }
        }
    }

    // MARK: - Non-Stream Response Parsing

    private nonisolated static func parseNonStream(
        data: Data,
        response: URLResponse,
        format: AIAPIFormat
    ) throws -> String {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch format {
        case .openAIResponses:
            let payload = try? JSONDecoder().decode(OpenAIResponsesPayload.self, from: data)
            if let message = payload?.error?.message, !message.isEmpty {
                throw AIChatError.apiError(message)
            }
            guard (200..<300).contains(statusCode) else {
                throw AIChatError.httpStatus(statusCode)
            }
            if let status = payload?.status, status != "completed" {
                let reason = payload?.incomplete_details?.reason.map { "（\($0)）" } ?? ""
                throw AIChatError.incompleteResponse("模型服务响应未完成：\(status)\(reason)，请重试")
            }
            if let status = payload?.output?.first(where: {
                ($0.type == nil || $0.type == "message") && $0.status != nil && $0.status != "completed"
            })?.status {
                throw AIChatError.incompleteResponse("模型服务消息未完成：\(status)，请重试")
            }
            let direct = payload?.output_text
            let text = direct ?? joinedResponsesOutputText(payload)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AIChatError.emptyResponse
            }
            return trimmed

        case .gemini:
            let envelopes = decodeGeminiEnvelopes(from: data)
            if let message = envelopes.compactMap({ $0.error?.message }).first(where: { !$0.isEmpty }) {
                throw AIChatError.apiError(message)
            }
            guard (200..<300).contains(statusCode) else {
                throw AIChatError.httpStatus(statusCode)
            }
            var partsText = ""
            var blockedReason: String?
            for envelope in envelopes {
                if let reason = envelope.promptFeedback?.blockReason, !reason.isEmpty {
                    blockedReason = reason
                }
                if let candidate = envelope.candidates?.first {
                    if let finishReason = candidate.finishReason, isGeminiBlockingFinishReason(finishReason) {
                        blockedReason = finishReason
                    }
                    partsText += extractGeminiVisibleText(from: candidate)
                }
            }
            let trimmed = partsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            if let blockedReason {
                throw AIChatError.blocked(blockedReason)
            }
            throw AIChatError.emptyResponse

        case .openAIChatCompletions:
            let payload = try? JSONDecoder().decode(OpenAIChatCompletionsPayload.self, from: data)
            if let message = payload?.error?.message, !message.isEmpty {
                throw AIChatError.apiError(message)
            }
            guard (200..<300).contains(statusCode) else {
                throw AIChatError.httpStatus(statusCode)
            }
            let choice = payload?.choices?.first
            let rawText = choice?.message?.textContent ?? ""
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            if choice?.finish_reason == "content_filter" {
                throw AIChatError.blocked("content_filter")
            }
            throw AIChatError.emptyResponse
        }
    }

    private nonisolated static func extractHTTPError(
        data: Data,
        statusCode: Int,
        format: AIAPIFormat
    ) -> AIChatError {
        switch format {
        case .gemini:
            let envelopes = decodeGeminiEnvelopes(from: data)
            if let message = envelopes.compactMap({ $0.error?.message }).first(where: { !$0.isEmpty }) {
                return .apiError(message)
            }
        case .openAIResponses:
            if let message = (try? JSONDecoder().decode(OpenAIResponsesPayload.self, from: data))?.error?.message,
               !message.isEmpty {
                return .apiError(message)
            }
        case .openAIChatCompletions:
            if let message = (try? JSONDecoder().decode(OpenAIChatCompletionsPayload.self, from: data))?.error?.message,
               !message.isEmpty {
                return .apiError(message)
            }
        }
        return .httpStatus(statusCode)
    }

    // MARK: - Payload DTOs

    private struct APIErrorBody: Decodable {
        let message: String?
    }

    private struct OpenAIResponsesPayload: Decodable {
        struct OutputItem: Decodable {
            struct ContentItem: Decodable {
                let type: String?
                let text: String?
            }
            let type: String?
            let status: String?
            let content: [ContentItem]?
        }
        struct IncompleteDetails: Decodable {
            let reason: String?
        }
        let status: String?
        let incomplete_details: IncompleteDetails?
        let output: [OutputItem]?
        let output_text: String?
        let error: APIErrorBody?
    }

    private struct OpenAIResponsesStreamEvent: Decodable {
        let type: String?
        let delta: String?
        let message: String?
        let error: APIErrorBody?
        let response: OpenAIResponsesPayload?
    }

    private struct GeminiResponsePayload: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        struct PromptFeedback: Decodable {
            let blockReason: String?
        }
        struct GeminiErrorBody: Decodable {
            let code: Int?
            let message: String?
            let status: String?
        }
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
        let error: GeminiErrorBody?
    }

    private struct OpenAIChatCompletionsPayload: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct ContentPart: Decodable {
                    let type: String?
                    let text: String?
                }
                let textContent: String?

                enum CodingKeys: String, CodingKey {
                    case content
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    if let string = try? container.decode(String.self, forKey: .content) {
                        textContent = string
                    } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
                        textContent = parts.compactMap(\.text).joined()
                    } else {
                        textContent = nil
                    }
                }
            }
            let message: Message?
            let finish_reason: String?
        }
        let choices: [Choice]?
        let error: APIErrorBody?
    }

    private struct OpenAIChatCompletionsStreamPayload: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta?
            let finish_reason: String?
        }
        let choices: [Choice]?
        let error: APIErrorBody?
    }

    private nonisolated static func joinedResponsesOutputText(_ payload: OpenAIResponsesPayload?) -> String {
        guard let output = payload?.output else { return "" }
        return output.compactMap { item in
            guard item.type == nil || item.type == "message" else { return nil }
            return item.content?
                .compactMap { $0.type == "output_text" ? $0.text : nil }
                .joined()
        }
        .joined()
    }

    private nonisolated static func decodeGeminiEnvelopes(from data: Data) -> [GeminiResponsePayload] {
        if let single = try? JSONDecoder().decode(GeminiResponsePayload.self, from: data) {
            return [single]
        }
        if let array = try? JSONDecoder().decode([GeminiResponsePayload].self, from: data) {
            return array
        }
        return []
    }

    private nonisolated static func extractGeminiVisibleText(
        from candidate: GeminiResponsePayload.Candidate
    ) -> String {
        guard let parts = candidate.content?.parts else { return "" }
        return parts.compactMap { part -> String? in
            // 严禁把 Gemini 2.5 思考链（thought: true）混入正式回答或译文。
            guard part.thought != true else { return nil }
            return part.text
        }
        .joined()
    }

    private nonisolated static let geminiBlockingReasons: Set<String> = [
        "SAFETY",
        "RECITATION",
        "BLOCKLIST",
        "PROHIBITED_CONTENT",
        "SPII",
        "IMAGE_SAFETY"
    ]

    private nonisolated static func isGeminiBlockingFinishReason(_ reason: String) -> Bool {
        geminiBlockingReasons.contains(reason.uppercased())
    }
}

// MARK: - Byte-Safe SSE Framing

private struct SSELineBuffer {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newlineIndex]
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }

    mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        var remaining = buffer
        buffer.removeAll(keepingCapacity: false)
        if remaining.last == 0x0D {
            remaining = remaining.dropLast()
        }
        return String(decoding: remaining, as: UTF8.self)
    }
}

private struct SSEEventParser {
    private var pendingDataLines: [String] = []
    private(set) var sawSSE = false

    mutating func consume(line: String) -> [String] {
        if line.isEmpty {
            return flushPending()
        }
        if line.hasPrefix(":")
            || line.hasPrefix("event:")
            || line.hasPrefix("id:")
            || line.hasPrefix("retry:") {
            sawSSE = true
            return []
        }
        if line.hasPrefix("data:") {
            sawSSE = true
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") {
                payload.removeFirst()
            }
            if pendingDataLines.isEmpty {
                let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "[DONE]" || Self.isCompleteJSON(payload) {
                    return [payload]
                }
            }
            pendingDataLines.append(payload)
            return []
        }
        return []
    }

    mutating func finish() -> [String] {
        flushPending()
    }

    private mutating func flushPending() -> [String] {
        guard !pendingDataLines.isEmpty else { return [] }
        let joined = pendingDataLines.joined(separator: "\n")
        pendingDataLines.removeAll(keepingCapacity: true)
        return [joined]
    }

    private static func isCompleteJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
    }
}
