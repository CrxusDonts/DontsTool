import Foundation

@MainActor
public protocol TranslationServicing: AnyObject {
    /// baseURL、模型与密钥都已配置时才提供系统翻译项。
    var isConfigured: Bool { get }
    func translate(_ text: String, target: String) async throws -> String
}

/// OpenAI Responses API 风格的翻译客户端（/responses）。
/// 文本只在用户显式执行翻译时发送到用户配置的端点，无后台网络。
@MainActor
public final class RemoteTranslationService: TranslationServicing {
    private let settings: SettingsStore
    private let secrets: SecretStoring
    private let http: HTTPRequesting
    private let timeout: Duration

    public init(
        settings: SettingsStore,
        secrets: SecretStoring,
        http: HTTPRequesting = URLSessionHTTPClient(),
        timeout: Duration = .seconds(30)
    ) {
        self.settings = settings
        self.secrets = secrets
        self.http = http
        self.timeout = timeout
    }

    public var isConfigured: Bool {
        !settings.translationAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.translationAPIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(secrets.secret(for: SecretAccount.translationAPIKey) ?? "").isEmpty
    }

    public func translate(_ text: String, target: String) async throws -> String {
        guard isConfigured else {
            throw ActionError.translationFailed("翻译 API 未配置，请在设置中填写")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ActionError.invalidInput("翻译内容为空")
        }

        let request = try makeRequest(text: trimmed, target: target)
        let (data, response) = try await http.data(for: request)
        return try Self.parse(data: data, response: response)
    }

    private func makeRequest(text: String, target: String) throws -> URLRequest {
        let base = settings.translationAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = base.contains("://") ? "\(base)/responses" : "https://\(base)/responses"
        guard let url = URL(string: endpoint) else {
            throw ActionError.translationFailed("翻译 API 地址无效")
        }
        guard let key = secrets.secret(for: SecretAccount.translationAPIKey), !key.isEmpty else {
            throw ActionError.translationFailed("翻译 API 密钥缺失")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeout.components.seconds)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": settings.translationAPIModel,
            "instructions": instructions(for: target),
            "input": text
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    private func instructions(for target: String) -> String {
        let name = Locale(identifier: "en").localizedString(forIdentifier: target) ?? target
        return """
        You are a translation engine. Translate the user's text into \(name). \
        Reply with only the translated text, preserving line breaks and formatting. \
        Do not add explanations, notes, or quotation marks.
        """
    }

    private struct ResponsesPayload: Decodable {
        struct OutputItem: Decodable {
            struct ContentItem: Decodable {
                let type: String?
                let text: String?
            }
            let type: String?
            let status: String?
            let content: [ContentItem]?
        }
        struct ErrorBody: Decodable {
            let message: String?
        }
        struct IncompleteDetails: Decodable {
            let reason: String?
        }
        let status: String?
        let incomplete_details: IncompleteDetails?
        let output: [OutputItem]?
        let output_text: String?
        let error: ErrorBody?
    }

    private static func parse(data: Data, response: URLResponse) throws -> String {
        let payload = try? JSONDecoder().decode(ResponsesPayload.self, from: data)
        if let message = payload?.error?.message, !message.isEmpty {
            throw ActionError.translationFailed(message)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ActionError.translationFailed("翻译服务返回 HTTP \(status)")
        }
        if let status = payload?.status, status != "completed" {
            let reason = payload?.incomplete_details?.reason.map { "（\($0)）" } ?? ""
            throw ActionError.translationFailed("翻译服务响应未完成：\(status)\(reason)，请重试")
        }
        if let status = payload?.output?.first(where: {
            ($0.type == nil || $0.type == "message") && $0.status != nil && $0.status != "completed"
        })?.status {
            throw ActionError.translationFailed("翻译服务消息未完成：\(status)，请重试")
        }
        let direct: String? = payload?.output_text ?? nil
        let text = direct ?? joinedOutputText(payload)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ActionError.translationFailed("翻译服务返回空结果")
        }
        return trimmed
    }

    private static func joinedOutputText(_ payload: ResponsesPayload?) -> String {
        guard let output = payload?.output else { return "" }
        return output.compactMap { item in
            guard item.type == nil || item.type == "message" else { return nil }
            let text = item.content?
                .compactMap { $0.type == "output_text" ? $0.text : nil }
                .joined()
            return text
        }
        .joined()
    }
}
