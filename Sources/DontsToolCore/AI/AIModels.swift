import Foundation

public enum AIAPIFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAIResponses = "openai_responses"
    case gemini = "gemini"
    case openAIChatCompletions = "openai_chat"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAIResponses: "OpenAI Responses"
        case .gemini: "Gemini 原生"
        case .openAIChatCompletions: "OpenAI Chat Completions"
        }
    }

    public var defaultBaseURLPlaceholder: String {
        switch self {
        case .openAIResponses: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .openAIChatCompletions: "https://api.deepseek.com/v1"
        }
    }

    public var defaultModelPlaceholder: String {
        switch self {
        case .openAIResponses: "gpt-4.1-mini"
        case .gemini: "gemini-2.5-flash"
        case .openAIChatCompletions: "deepseek-chat"
        }
    }
}

public enum AIChatRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public struct AIChatMessage: Codable, Equatable, Sendable {
    public let role: AIChatRole
    public let content: String

    public init(role: AIChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct QuickAIRequest: Equatable, Sendable {
    public let title: String?
    public let prompt: String
    public let systemPrompt: String?
    public let autoSend: Bool

    public init(
        title: String? = nil,
        prompt: String,
        systemPrompt: String? = nil,
        autoSend: Bool = true
    ) {
        self.title = title
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.autoSend = autoSend
    }
}

public struct QuickAIMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: AIChatRole
    public var content: String
    public var isStreaming: Bool
    public var errorMessage: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: AIChatRole,
        content: String,
        isStreaming: Bool = false,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}

public enum AIChatError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case emptyInput
    case invalidEndpoint(String)
    case missingAPIKey
    case httpStatus(Int)
    case apiError(String)
    case incompleteResponse(String)
    case blocked(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "大模型服务未配置，请在「设置 → AI 与翻译」填写接口地址、模型和 API 密钥"
        case .emptyInput:
            "提问内容为空"
        case .invalidEndpoint(let message):
            message
        case .missingAPIKey:
            "API 密钥缺失，请在「设置 → AI 与翻译」填写密钥"
        case .httpStatus(let code):
            "模型服务返回 HTTP \(code)"
        case .apiError(let message):
            message
        case .incompleteResponse(let message):
            message
        case .blocked(let reason):
            "响应被模型安全策略拦截（\(reason)）"
        case .emptyResponse:
            "模型服务返回空结果"
        }
    }
}
