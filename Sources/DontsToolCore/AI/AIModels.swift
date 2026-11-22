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

public enum AIUsagePurpose: String, CaseIterable, Identifiable, Codable, Sendable {
    case general
    case translation
    case quickAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: "默认"
        case .translation: "翻译与划词"
        case .quickAI: "AI 快问"
        }
    }

    public var consumerID: String? {
        switch self {
        case .general: nil
        case .translation: AIConsumerID.translation
        case .quickAI: AIConsumerID.legacyQuickAIPlugin
        }
    }
}

public enum AIConsumerID {
    public static let translation = "builtin.translation"
    public static let legacyQuickAIPlugin = "plugin.com.donts.quick-ai"

    public static func plugin(_ pluginID: String) -> String {
        "plugin.\(pluginID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

public enum AIConsumerSource: Equatable, Hashable, Sendable {
    case builtIn
    case plugin(id: String)
}

public struct AIConsumerDescriptor: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let source: AIConsumerSource
    public let badgeTitle: String

    public init(
        id: String,
        title: String,
        subtitle: String,
        source: AIConsumerSource,
        badgeTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.source = source
        let trimmedBadge = badgeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.badgeTitle = (trimmedBadge?.isEmpty == false) ? trimmedBadge! : title
    }
}

public struct AIModelProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var format: AIAPIFormat
    public var baseURL: String
    public var model: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        format: AIAPIFormat = .openAIResponses,
        baseURL: String,
        model: String
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.baseURL = baseURL
        self.model = model
    }

    public var secretAccount: String {
        SecretAccount.aiModelProfileAPIKey(id: id)
    }

    public var displayHost: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        if let components = URLComponents(string: candidate),
           let host = components.host, !host.isEmpty {
            if let port = components.port {
                return "\(host):\(port)"
            }
            return host
        }
        return trimmed
    }
}

public struct ResolvedAIConfiguration: Equatable, Sendable {
    public let profileID: String?
    public let profileName: String?
    public let format: AIAPIFormat
    public let baseURL: String
    public let model: String
    public let secretAccount: String

    public init(
        profileID: String?,
        profileName: String?,
        format: AIAPIFormat,
        baseURL: String,
        model: String,
        secretAccount: String
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.format = format
        self.baseURL = baseURL
        self.model = model
        self.secretAccount = secretAccount
    }

    public var isEndpointComplete: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var displaySummary: String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = profileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty && !trimmedModel.isEmpty {
            if trimmedName.caseInsensitiveCompare(trimmedModel) == .orderedSame {
                return "\(format.displayName) · \(trimmedModel)"
            }
            return "\(trimmedName) · \(trimmedModel)"
        }
        if !trimmedName.isEmpty {
            return trimmedName
        }
        guard !trimmedModel.isEmpty else { return "未配置模型" }
        return "\(format.displayName) · \(trimmedModel)"
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
    public let consumerID: String?

    public init(
        title: String? = nil,
        prompt: String,
        systemPrompt: String? = nil,
        autoSend: Bool = true,
        consumerID: String? = nil
    ) {
        self.title = title
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.autoSend = autoSend
        self.consumerID = consumerID
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
            "大模型服务未配置，请在「设置 → 模型服务」添加接口地址、模型和 API 密钥"
        case .emptyInput:
            "提问内容为空"
        case .invalidEndpoint(let message):
            message
        case .missingAPIKey:
            "API 密钥缺失，请在「设置 → 模型服务」填写密钥"
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
