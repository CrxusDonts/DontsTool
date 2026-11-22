import Foundation
import os
import Testing
@testable import DontsToolCore

private final class MockStreamingHTTPClient: HTTPStreaming, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var requests: [URLRequest] = []
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var chunks: [Data] = []
        var delayBetweenChunks: Duration?
        var terminatedCount: Int = 0
        var error: (any Error)?
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    var terminatedCount: Int {
        state.withLock { $0.terminatedCount }
    }

    func configure(
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "text/event-stream"],
        chunks: [Data],
        delayBetweenChunks: Duration? = nil,
        error: (any Error)? = nil
    ) {
        state.withLock { state in
            state.statusCode = statusCode
            state.headers = headers
            state.chunks = chunks
            state.delayBetweenChunks = delayBetweenChunks
            state.error = error
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = state.withLock { state -> (statusCode: Int, headers: [String: String], body: Data, error: (any Error)?) in
            state.requests.append(request)
            var joined = Data()
            for chunk in state.chunks { joined.append(chunk) }
            return (statusCode: state.statusCode, headers: state.headers, body: joined, error: state.error)
        }
        if let error = snapshot.error { throw error }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: snapshot.statusCode,
            httpVersion: "1.1",
            headerFields: snapshot.headers
        )!
        return (snapshot.body, response)
    }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        let snapshot = state.withLock { state -> (statusCode: Int, headers: [String: String], chunks: [Data], delay: Duration?, error: (any Error)?) in
            state.requests.append(request)
            return (
                statusCode: state.statusCode,
                headers: state.headers,
                chunks: state.chunks,
                delay: state.delayBetweenChunks,
                error: state.error
            )
        }
        if let error = snapshot.error { throw error }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: snapshot.statusCode,
            httpVersion: "1.1",
            headerFields: snapshot.headers
        )!
        let lockState = state
        let dataStream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    for chunk in snapshot.chunks {
                        try Task.checkCancellation()
                        if let delay = snapshot.delay {
                            try await Task.sleep(for: delay)
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                lockState.withLock { $0.terminatedCount += 1 }
                task.cancel()
            }
        }
        return (dataStream, response)
    }
}

@Suite("AIChatService")
@MainActor
struct AIChatServiceTests {
    private func makeFixture(
        format: AIAPIFormat = .openAIResponses,
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4.1-mini",
        key: String? = "sk-secret-test",
        http: HTTPRequesting? = nil
    ) -> (
        service: RemoteAIChatService,
        settings: SettingsStore,
        secrets: MemorySecretStore,
        defaults: UserDefaults,
        suite: String
    ) {
        let suite = "AIChatServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        settings.setAIAPIFormat(format)
        settings.setTranslationAPIBaseURL(baseURL)
        settings.setTranslationAPIModel(model)
        let secrets = MemorySecretStore()
        secrets.setSecret(key, for: SecretAccount.translationAPIKey)
        let client = http ?? MockStreamingHTTPClient()
        let service = RemoteAIChatService(settings: settings, secrets: secrets, http: client)
        return (service, settings, secrets, defaults, suite)
    }

    // MARK: - OpenAI Responses

    @Test func openAIResponsesStreamsDeltasAndMultiTurnInput() async throws {
        let http = MockStreamingHTTPClient()
        let sse = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"你好"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"，Swift 6！"}

        event: response.completed
        data: {"type":"response.completed","response":{"status":"completed"}}

        """
        http.configure(chunks: [Data(sse.utf8)])

        let fixture = makeFixture(format: .openAIResponses, http: http)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        var deltas: [String] = []
        let stream = fixture.service.stream(
            messages: [
                AIChatMessage(role: .user, content: "你好"),
                AIChatMessage(role: .assistant, content: "你好！"),
                AIChatMessage(role: .user, content: "介绍一下 Swift 6")
            ],
            systemPrompt: "你是简洁助手"
        )
        for try await chunk in stream {
            deltas.append(chunk)
        }

        #expect(deltas == ["你好", "，Swift 6！"])
        let req = try #require(http.requests.first)
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret-test")
        #expect(req.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        #expect(body?["model"] as? String == "gpt-4.1-mini")
        #expect(body?["instructions"] as? String == "你是简洁助手")
        #expect(body?["stream"] as? Bool == true)
        let inputArray = body?["input"] as? [[String: String]]
        #expect(inputArray?.count == 3)
        #expect(inputArray?[1]["role"] == "assistant")
    }

    @Test func streamFallsBackToNonStreamingHTTPRequestingAndJSONPayload() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Data(#"{"status":"completed","output_text":"非流式回退成功"}"#.utf8)

        let fixture = makeFixture(format: .openAIResponses, http: mock)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        var collected = ""
        for try await delta in fixture.service.stream(messages: [AIChatMessage(role: .user, content: "hi")]) {
            collected += delta
        }
        #expect(collected == "非流式回退成功")
        #expect(mock.requests.count == 1)
    }

    @Test func openAIResponsesStreamSurfacesFailedEvent() async {
        let http = MockStreamingHTTPClient()
        let sse = """
        data: {"type":"response.failed","response":{"error":{"message":"rate limit exceeded"}}}

        """
        http.configure(chunks: [Data(sse.utf8)])

        let fixture = makeFixture(format: .openAIResponses, http: http)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        await #expect(throws: AIChatError.apiError("rate limit exceeded")) {
            for try await _ in fixture.service.stream(messages: [AIChatMessage(role: .user, content: "hi")]) {}
        }
    }

    // MARK: - Gemini Native REST API

    @Test(arguments: [
        (
            "https://generativelanguage.googleapis.com",
            "gemini-2.5-flash",
            false,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        ),
        (
            "https://generativelanguage.googleapis.com",
            "models/gemini-2.5-flash",
            true,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
        ),
        (
            "generativelanguage.googleapis.com/v1beta/",
            "gemini-2.5-pro",
            true,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse"
        ),
        (
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
            "gemini-2.5-flash",
            true,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
        ),
        (
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
            "gemini-2.5-flash",
            false,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        )
    ])
    func geminiURLNormalizationHandlesAllPatterns(
        baseURL: String,
        model: String,
        stream: Bool,
        expected: String
    ) throws {
        let resolved = try RemoteAIChatService.resolveEndpointURL(
            baseURL: baseURL,
            model: model,
            format: .gemini,
            stream: stream
        )
        #expect(resolved.absoluteString == expected)
    }

    @Test func geminiUsesHeaderAuthFiltersThoughtPartsAndMapsModelRole() async throws {
        let http = MockStreamingHTTPClient()
        let responseJSON = """
        {
          "candidates": [
            {
              "content": {
                "role": "model",
                "parts": [
                  {"text": "内部思考过程不应该暴露", "thought": true},
                  {"text": "这是最终回答。"}
                ]
              },
              "finishReason": "STOP"
            }
          ]
        }
        """
        http.configure(headers: ["Content-Type": "application/json"], chunks: [Data(responseJSON.utf8)])

        let fixture = makeFixture(
            format: .gemini,
            baseURL: "https://generativelanguage.googleapis.com",
            model: "models/gemini-2.5-flash",
            key: "AIza-secret-header-only",
            http: http
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        let answer = try await fixture.service.complete(
            messages: [
                AIChatMessage(role: .user, content: "第一句"),
                AIChatMessage(role: .assistant, content: "收到"),
                AIChatMessage(role: .user, content: "总结一下")
            ],
            systemPrompt: "请用中文回答"
        )
        #expect(answer == "这是最终回答。")

        let req = try #require(http.requests.first)
        let urlString = try #require(req.url?.absoluteString)
        #expect(urlString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(!urlString.contains("AIza-secret-header-only"))
        #expect(!urlString.contains("key="))
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-secret-header-only")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        let systemParts = (body?["systemInstruction"] as? [String: Any])?["parts"] as? [[String: String]]
        #expect(systemParts?.first?["text"] == "请用中文回答")
        let contents = body?["contents"] as? [[String: Any]]
        #expect(contents?.count == 3)
        #expect(contents?[0]["role"] as? String == "user")
        #expect(contents?[1]["role"] as? String == "model")
        #expect(contents?[2]["role"] as? String == "user")
    }

    @Test func geminiStreamFiltersThoughtsHandlesSafetyBlockAndArrayErrors() async throws {
        // 1. Streaming SSE filters out thought: true parts
        let http = MockStreamingHTTPClient()
        let sse = """
        data: {"candidates":[{"content":{"parts":[{"text":"秘密思考...","thought":true}]}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"答案第一段"}]}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"，第二段。"}]},"finishReason":"STOP"}]}

        """
        http.configure(chunks: [Data(sse.utf8)])

        let fixture = makeFixture(
            format: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            model: "gemini-2.5-flash",
            key: "AIza-key",
            http: http
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        var parts: [String] = []
        for try await chunk in fixture.service.stream(messages: [AIChatMessage(role: .user, content: "hi")]) {
            parts.append(chunk)
        }
        #expect(parts == ["答案第一段", "，第二段。"])
        let req = try #require(http.requests.first)
        #expect(req.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-key")

        // 2. Safety block with empty text surfaces clear Chinese error
        let safetyJSON = #"{"candidates":[{"content":{"parts":[]},"finishReason":"SAFETY"}]}"#
        http.configure(headers: ["Content-Type": "application/json"], chunks: [Data(safetyJSON.utf8)])
        await #expect(throws: AIChatError.blocked("SAFETY")) {
            _ = try await fixture.service.complete(messages: [AIChatMessage(role: .user, content: "blocked")])
        }

        // 3. Array-wrapped Gemini error envelope (typical on streaming HTTP 400/403)
        let arrayErrorJSON = #"[{"error":{"code":403,"message":"API key not valid","status":"PERMISSION_DENIED"}}]"#
        http.configure(statusCode: 403, headers: ["Content-Type": "application/json"], chunks: [Data(arrayErrorJSON.utf8)])
        await #expect(throws: AIChatError.apiError("API key not valid")) {
            for try await _ in fixture.service.stream(messages: [AIChatMessage(role: .user, content: "hi")]) {}
        }
    }

    // MARK: - OpenAI Chat Completions

    @Test func openAIChatCompletionsStreamsAndIgnoresDoneSentinel() async throws {
        let http = MockStreamingHTTPClient()
        let sse = """
        data: {"choices":[{"delta":{"role":"assistant","content":"Deep"}}]}

        data: {"choices":[{"delta":{"content":"Seek 响应"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        http.configure(chunks: [Data(sse.utf8)])

        let fixture = makeFixture(
            format: .openAIChatCompletions,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            key: "sk-ds",
            http: http
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        var output = ""
        for try await delta in fixture.service.stream(
            messages: [AIChatMessage(role: .user, content: "你好")],
            systemPrompt: "系统规则"
        ) {
            output += delta
        }
        #expect(output == "DeepSeek 响应")

        let req = try #require(http.requests.first)
        #expect(req.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ds")

        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        let sentMessages = body?["messages"] as? [[String: String]]
        #expect(sentMessages?.count == 2)
        #expect(sentMessages?[0]["role"] == "system")
        #expect(sentMessages?[0]["content"] == "系统规则")
        #expect(sentMessages?[1]["role"] == "user")
    }

    // MARK: - Byte-Safe UTF-8 & Cancellation

    @Test func sseLineBufferHandlesMultiByteUTF8SplitAcrossChunks() async throws {
        let http = MockStreamingHTTPClient()
        let fullEvent = Data("data: {\"choices\":[{\"delta\":{\"content\":\"中文多字节测试🚀完成\"}}]}\n\ndata: [DONE]\n\n".utf8)
        // Slice every 2 bytes so every 3-byte Chinese char and 4-byte emoji crosses chunk boundaries!
        var splitChunks: [Data] = []
        var offset = 0
        while offset < fullEvent.count {
            let end = min(offset + 2, fullEvent.count)
            splitChunks.append(fullEvent.subdata(in: offset..<end))
            offset = end
        }
        http.configure(chunks: splitChunks)

        let fixture = makeFixture(
            format: .openAIChatCompletions,
            baseURL: "https://api.example.com/v1",
            model: "test-model",
            http: http
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        var result = ""
        for try await delta in fixture.service.stream(messages: [AIChatMessage(role: .user, content: "utf8")]) {
            result += delta
        }
        #expect(result == "中文多字节测试🚀完成")
        #expect(!result.contains("\u{FFFD}"))
    }

    @Test func cancellingStreamTerminatesUnderlyingRequestCleanly() async throws {
        let http = MockStreamingHTTPClient()
        let chunks = (0..<20).map { index in
            Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"chunk-\(index) \"}\n\n".utf8)
        }
        http.configure(chunks: chunks, delayBetweenChunks: .milliseconds(30))

        let fixture = makeFixture(format: .openAIResponses, http: http)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        var received: [String] = []
        let consumer = Task {
            for try await delta in fixture.service.stream(messages: [AIChatMessage(role: .user, content: "long")]) {
                received.append(delta)
                if received.count >= 2 {
                    break
                }
            }
        }
        try await consumer.value
        #expect(received.count == 2)
        #expect(http.terminatedCount >= 1)
    }

    // MARK: - RemoteTranslationService Multi-Format Reuse

    @Test func remoteTranslationServiceSupportsGeminiAndChatCompletionsFormats() async throws {
        let suite = "RemoteTranslationMultiFormat-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        let secrets = MemorySecretStore()
        secrets.setSecret("AIza-translate-key", for: SecretAccount.translationAPIKey)

        // Gemini format with thought part filtered out
        let geminiHTTP = MockHTTPClient()
        geminiHTTP.responseData = Data("""
        {
          "candidates": [{
            "content": {
              "parts": [
                {"text": "thinking about nuance...", "thought": true},
                {"text": "你好，世界"}
              ]
            },
            "finishReason": "STOP"
          }]
        }
        """.utf8)
        settings.setAIAPIFormat(.gemini)
        settings.setTranslationAPIBaseURL("https://generativelanguage.googleapis.com")
        settings.setTranslationAPIModel("gemini-2.5-flash")

        let geminiTranslator = RemoteTranslationService(settings: settings, secrets: secrets, http: geminiHTTP)
        let translated = try await geminiTranslator.translate("Hello, world", target: "zh-Hans")
        #expect(translated == "你好，世界")
        let geminiReq = try #require(geminiHTTP.requests.first)
        #expect(geminiReq.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(geminiReq.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-translate-key")

        // Chat Completions format
        let chatHTTP = MockHTTPClient()
        chatHTTP.responseData = Data(#"{"choices":[{"message":{"content":"Bonjour"}}]}"#.utf8)
        settings.setAIAPIFormat(.openAIChatCompletions)
        settings.setTranslationAPIBaseURL("https://api.deepseek.com/v1")
        settings.setTranslationAPIModel("deepseek-chat")
        secrets.setSecret("sk-chat-key", for: SecretAccount.translationAPIKey)

        let chatTranslator = RemoteTranslationService(settings: settings, secrets: secrets, http: chatHTTP)
        let french = try await chatTranslator.translate("Hello", target: "fr")
        #expect(french == "Bonjour")
        let chatReq = try #require(chatHTTP.requests.first)
        #expect(chatReq.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(chatReq.value(forHTTPHeaderField: "Authorization") == "Bearer sk-chat-key")
    }

    // MARK: - Multi-Profile Binding & Connection Test

    @Test func multiProfileSeparatesTranslationAndQuickAIEndpointsFormatsAndKeys() async throws {
        let suite = "MultiProfileRouting-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        let secrets = MemorySecretStore()

        let geminiProfile = AIModelProfile(
            id: "trans-gemini",
            name: "翻译用 Gemini",
            format: .gemini,
            baseURL: "https://generativelanguage.googleapis.com",
            model: "gemini-2.5-flash"
        )
        let openaiProfile = AIModelProfile(
            id: "qa-openai",
            name: "问答用 OpenAI",
            format: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1-mini"
        )
        settings.upsertAIModelProfile(geminiProfile, makeDefault: true)
        settings.upsertAIModelProfile(openaiProfile)
        settings.saveAPIKey("AIza-trans-secret", for: geminiProfile, secrets: secrets)
        settings.saveAPIKey("sk-quickai-secret", for: openaiProfile, secrets: secrets)
        settings.setTranslationAIModelProfileID(geminiProfile.id)
        settings.setQuickAIAIModelProfileID(openaiProfile.id)

        let transHTTP = MockHTTPClient()
        transHTTP.responseData = Data("""
        {"candidates":[{"content":{"parts":[{"text":"你好"}]},"finishReason":"STOP"}]}
        """.utf8)
        let translator = RemoteTranslationService(settings: settings, secrets: secrets, http: transHTTP)

        let aiHTTP = MockHTTPClient()
        aiHTTP.responseData = Data(#"{"status":"completed","output_text":"Swift 6 并发安全"}"#.utf8)
        let quickAI = RemoteAIChatService(settings: settings, secrets: secrets, http: aiHTTP, purpose: .quickAI)

        #expect(translator.isConfigured)
        #expect(quickAI.isConfigured)
        #expect(quickAI.activeFormat == .openAIResponses)
        #expect(quickAI.activeProfileName == "问答用 OpenAI")
        #expect(quickAI.activeModelDisplay == "问答用 OpenAI · gpt-4.1-mini")

        let translated = try await translator.translate("hello", target: "zh-Hans")
        let answered = try await quickAI.complete(messages: [AIChatMessage(role: .user, content: "Swift 6?")])

        #expect(translated == "你好")
        #expect(answered == "Swift 6 并发安全")

        let transReq = try #require(transHTTP.requests.first)
        #expect(transReq.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(transReq.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-trans-secret")

        let aiReq = try #require(aiHTTP.requests.first)
        #expect(aiReq.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(aiReq.value(forHTTPHeaderField: "Authorization") == "Bearer sk-quickai-secret")
    }

    @Test func testConnectionValidatesAllThreeFormatsAndReportsErrors() async throws {
        let suite = "TestConnection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        let secrets = MemorySecretStore()

        // 1. OpenAI Responses success
        let responsesHTTP = MockHTTPClient()
        responsesHTTP.responseData = Data(#"{"status":"completed","output_text":"OK"}"#.utf8)
        let responsesService = RemoteAIChatService(settings: settings, secrets: secrets, http: responsesHTTP)
        let responsesDraft = AIModelProfile(
            name: "OpenAI Draft",
            format: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1-mini"
        )
        let rElapsed = try await responsesService.testConnection(for: responsesDraft, apiKey: "sk-probe-1")
        #expect(rElapsed >= 0)
        #expect(responsesHTTP.requests.first?.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(responsesHTTP.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-probe-1")

        // 2. Gemini Native success (header auth, filters thought)
        let geminiHTTP = MockHTTPClient()
        geminiHTTP.responseData = Data(#"{"candidates":[{"content":{"parts":[{"text":"thinking","thought":true},{"text":"OK"}]},"finishReason":"STOP"}]}"#.utf8)
        let geminiService = RemoteAIChatService(settings: settings, secrets: secrets, http: geminiHTTP)
        let geminiDraft = AIModelProfile(
            name: "Gemini Draft",
            format: .gemini,
            baseURL: "https://generativelanguage.googleapis.com",
            model: "gemini-2.5-flash"
        )
        let gElapsed = try await geminiService.testConnection(for: geminiDraft, apiKey: "AIza-probe")
        #expect(gElapsed >= 0)
        #expect(geminiHTTP.requests.first?.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(geminiHTTP.requests.first?.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-probe")

        // 3. OpenAI Chat Completions success
        let chatHTTP = MockHTTPClient()
        chatHTTP.responseData = Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        let chatService = RemoteAIChatService(settings: settings, secrets: secrets, http: chatHTTP)
        let chatDraft = AIModelProfile(
            name: "DeepSeek Draft",
            format: .openAIChatCompletions,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat"
        )
        let cElapsed = try await chatService.testConnection(for: chatDraft, apiKey: "sk-ds-probe")
        #expect(cElapsed >= 0)
        #expect(chatHTTP.requests.first?.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")

        // 4. Error handling: missing key & API 401
        await #expect(throws: AIChatError.missingAPIKey) {
            _ = try await chatService.testConnection(for: chatDraft, apiKey: "   ")
        }

        let errHTTP = MockHTTPClient()
        errHTTP.statusCode = 401
        errHTTP.responseData = Data(#"[{"error":{"code":401,"message":"Invalid Gemini key"}}]"#.utf8)
        let errService = RemoteAIChatService(settings: settings, secrets: secrets, http: errHTTP)
        await #expect(throws: AIChatError.apiError("Invalid Gemini key")) {
            _ = try await errService.testConnection(for: geminiDraft, apiKey: "AIza-bad")
        }
    }

    @Test func scopedRemoteAIChatServiceRoutesDistinctPluginConsumersAndFallback() async throws {
        let suite = "ScopedAIConsumer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "zh")
        let secrets = MemorySecretStore()

        let defaultProfile = AIModelProfile(
            id: "p-default",
            name: "Default OpenAI",
            format: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1-mini"
        )
        let reviewerProfile = AIModelProfile(
            id: "p-review",
            name: "DeepSeek Reviewer",
            format: .openAIChatCompletions,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-reasoner"
        )
        settings.upsertAIModelProfile(defaultProfile, makeDefault: true)
        settings.upsertAIModelProfile(reviewerProfile)
        settings.saveAPIKey("sk-default-secret", for: defaultProfile, secrets: secrets)
        settings.saveAPIKey("sk-review-secret", for: reviewerProfile, secrets: secrets)
        settings.setAIModelProfileID(reviewerProfile.id, forConsumerID: AIConsumerID.plugin("com.example.reviewer"))

        let http = MockHTTPClient()
        let baseService = RemoteAIChatService(settings: settings, secrets: secrets, http: http)
        let reviewerService = baseService.scoped(toConsumerID: AIConsumerID.plugin("com.example.reviewer"))
        let unboundService = baseService.scoped(toConsumerID: AIConsumerID.plugin("com.example.other"))

        #expect(baseService.activeProfileName == "Default OpenAI")
        #expect(unboundService.activeProfileName == "Default OpenAI")
        #expect(reviewerService.activeProfileName == "DeepSeek Reviewer")
        #expect(reviewerService.activeFormat == .openAIChatCompletions)

        http.responseData = Data(#"{"choices":[{"message":{"content":"审查完成"}}]}"#.utf8)
        let reviewAnswer = try await reviewerService.complete(messages: [AIChatMessage(role: .user, content: "Review diff")])
        #expect(reviewAnswer == "审查完成")
        #expect(http.requests.last?.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-review-secret")

        http.responseData = Data(#"{"status":"completed","output_text":"默认回复"}"#.utf8)
        let unboundAnswer = try await unboundService.complete(messages: [AIChatMessage(role: .user, content: "Hi")])
        #expect(unboundAnswer == "默认回复")
        #expect(http.requests.last?.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-default-secret")
    }
}
