import Foundation
import Testing
@testable import DontsToolCore

@Suite("RemoteTranslationService")
@MainActor
struct RemoteTranslationServiceTests {
    private func makeService(
        baseURL: String = "https://api.deepseek.com/v1",
        model: String = "deepseek-chat",
        key: String? = "sk-test"
    ) -> (RemoteTranslationService, MockHTTPClient, MemorySecretStore, SettingsStore) {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setTranslationAPIBaseURL(baseURL)
        settings.setTranslationAPIModel(model)
        let secrets = MemorySecretStore()
        secrets.setSecret(key, for: SecretAccount.translationAPIKey)
        let http = MockHTTPClient()
        let service = RemoteTranslationService(settings: settings, secrets: secrets, http: http)
        return (service, http, secrets, settings)
    }

    @Test func configuredRequiresBaseURLModelAndKey() {
        let (service, _, secrets, _) = makeService()
        #expect(service.isConfigured)
        secrets.setSecret(nil, for: SecretAccount.translationAPIKey)
        #expect(!service.isConfigured)
    }

    @Test func requestUsesResponsesEndpointWithBearerAndBody() async throws {
        let (service, http, _, _) = makeService()
        http.responseData = Data(#"{"output_text":"你好"}"#.utf8)
        _ = try await service.translate("hello", target: "zh-Hans")

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["model"] as? String == "deepseek-chat")
        #expect(body?["input"] as? String == "hello")
        #expect((body?["instructions"] as? String)?.contains("Chinese") == true)
    }

    @Test(arguments: [
        ("https://openrouter.ai/api/v1", "https://openrouter.ai/api/v1/responses"),
        ("https://openrouter.ai/api/v1/", "https://openrouter.ai/api/v1/responses"),
        ("https://openrouter.ai/api/v1/responses", "https://openrouter.ai/api/v1/responses"),
        ("https://openrouter.ai/api/v1/responses/", "https://openrouter.ai/api/v1/responses"),
        ("openrouter.ai/api/v1", "https://openrouter.ai/api/v1/responses"),
        ("openrouter.ai/api/v1/responses", "https://openrouter.ai/api/v1/responses"),
        ("http://localhost:8080/v1", "http://localhost:8080/v1/responses"),
        ("https://translation.example/v1?api-version=2025-04-01-preview", "https://translation.example/v1/responses?api-version=2025-04-01-preview"),
        ("https://translation.example/v1/responses/?api-version=2025-04-01-preview", "https://translation.example/v1/responses?api-version=2025-04-01-preview")
    ])
    func acceptsBaseURLOrCompleteEndpoint(_ configuredURL: String, _ expectedURL: String) async throws {
        let (service, http, _, _) = makeService(baseURL: configuredURL)
        http.responseData = Data(#"{"output_text":"你好"}"#.utf8)

        #expect(try await service.translate("hello", target: "zh-Hans") == "你好")
        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == expectedURL)
    }

    @Test(arguments: ["ftp://translation.example/v1", "file:///tmp/translation", "https:///v1", "https://", "https://invalid host/v1"])
    func rejectsInvalidEndpointWithoutSendingText(_ configuredURL: String) async {
        let (service, http, _, _) = makeService(baseURL: configuredURL)
        http.responseData = Data(#"{"output_text":"unexpected"}"#.utf8)

        await #expect(throws: ActionError.self) {
            _ = try await service.translate("must stay local", target: "zh-Hans")
        }
        #expect(http.requests.isEmpty)
    }

    @Test func parsesOutputText() async throws {
        let (service, http, _, _) = makeService()
        http.responseData = Data(#"{"output_text":" 你好 "}"#.utf8)
        let result = try await service.translate("hello", target: "zh-Hans")
        #expect(result == "你好")
    }

    @Test func parsesOutputArray() async throws {
        let (service, http, _, _) = makeService()
        http.responseData = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"你好世界"}]}]}"#.utf8)
        let result = try await service.translate("hello world", target: "zh-Hans")
        #expect(result == "你好世界")
    }

    @Test func errorBodyIsMappedToReadableError() async {
        let (service, http, _, _) = makeService()
        http.statusCode = 401
        http.responseData = Data(#"{"error":{"message":"invalid api key"}}"#.utf8)
        await #expect(throws: (any Error).self) {
            _ = try await service.translate("hello", target: "zh-Hans")
        }
    }

    @Test func httpFailureReportsStatus() async {
        let (service, http, _, _) = makeService()
        http.statusCode = 500
        http.responseData = Data("oops".utf8)
        do {
            _ = try await service.translate("hello", target: "zh-Hans")
            Issue.record("expected throw")
        } catch let error as ActionError {
            #expect(error.errorDescription?.contains("500") == true)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func emptyResultThrows() async {
        let (service, http, _, _) = makeService()
        http.responseData = Data(#"{"output_text":"   "}"#.utf8)
        await #expect(throws: (any Error).self) {
            _ = try await service.translate("hello", target: "zh-Hans")
        }
    }

    @Test(arguments: ["baseURL", "model", "key"])
    func missingConfigurationExplainsSetupWithoutNetwork(_ missing: String) async {
        let (service, http, _, _) = makeService(
            baseURL: missing == "baseURL" ? "" : "https://translation.example/v1",
            model: missing == "model" ? "" : "translation-model",
            key: missing == "key" ? nil : "test-key"
        )
        do {
            _ = try await service.translate("hello", target: "zh-Hans")
            Issue.record("缺少大模型配置时应提示设置，不应返回译文")
        } catch let error as ActionError {
            let message = error.localizedDescription
            #expect(message.contains("设置 → 翻译"))
            #expect(message.contains("接口地址"))
            #expect(message.contains("模型"))
            #expect(message.contains("API 密钥"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(http.requests.isEmpty)
    }

    @Test(arguments: ["incomplete", "failed", "cancelled", "queued", "in_progress"])
    func rejectsUnfinishedResponseWithPartialOutput(_ status: String) async throws {
        let (service, http, _, _) = makeService()
        let payload: [String: Any] = [
            "status": status,
            "incomplete_details": ["reason": "max_output_tokens"],
            "output_text": "部分译文",
            "output": [["type": "message", "status": "completed", "content": [["type": "output_text", "text": "部分译文"]]]]
        ]
        http.responseData = try JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try await service.translate("hello", target: "zh-Hans")
            Issue.record("未完成的翻译响应被当作成功结果")
        } catch let error as ActionError {
            #expect(error.localizedDescription.contains(status))
        }
    }

    @Test(arguments: ["incomplete", "failed", "cancelled", "in_progress"])
    func rejectsUnfinishedMessageEvenWhenResponseCompleted(_ status: String) async throws {
        let (service, http, _, _) = makeService()
        let payload: [String: Any] = [
            "status": "completed",
            "output_text": "部分译文",
            "output": [["type": "message", "status": status, "content": [["type": "output_text", "text": "部分译文"]]]]
        ]
        http.responseData = try JSONSerialization.data(withJSONObject: payload)
        await #expect(throws: ActionError.self) {
            _ = try await service.translate("hello", target: "zh-Hans")
        }
    }

    @Test func completedResponseAndMessageProduceTranslation() async throws {
        let (service, http, _, _) = makeService()
        http.responseData = Data(#"{"status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"你好"}]}]}"#.utf8)
        #expect(try await service.translate("hello", target: "zh-Hans") == "你好")
    }
}
