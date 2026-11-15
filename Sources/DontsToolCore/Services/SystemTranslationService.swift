import Foundation
import NaturalLanguage
@preconcurrency import Translation

@MainActor
protocol SystemTranslationSession: AnyObject, Sendable {
    func translate(_ text: String) async throws -> String
    func cancel()
}

@MainActor
protocol SystemTranslationBackend {
    func availability(source: String, target: String) async -> LanguageAvailability.Status
    func session(source: String, target: String) -> any SystemTranslationSession
}

@MainActor
public final class SystemTranslationService: TranslationServicing {
    private let backend: any SystemTranslationBackend
    private let identifyLanguage: (String) -> String?
    public var isConfigured: Bool { true }

    public convenience init() {
        self.init(backend: AppleTranslationBackend(), identifyLanguage: { text in
            NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        })
    }

    init(backend: any SystemTranslationBackend, identifyLanguage: @escaping (String) -> String?) {
        self.backend = backend
        self.identifyLanguage = identifyLanguage
    }

    public func translate(_ text: String, target: String) async throws -> String {
        try Task.checkCancellation()
        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { throw ActionError.invalidInput("翻译内容为空") }
        guard let source = identifyLanguage(sourceText) else {
            throw ActionError.translationFailed("无法识别原文语言，请补充文字后重试")
        }
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        if sourceLanguage.minimalIdentifier == targetLanguage.minimalIdentifier { return sourceText }
        let availability = await backend.availability(source: source, target: target)
        try Task.checkCancellation()
        switch availability {
        case .supported:
            throw ActionError.translationFailed("请先下载翻译语言包，再重试系统翻译")
        case .unsupported:
            throw ActionError.translationFailed("系统翻译不支持此语言组合，请在设置中选择其他目标语言或配置翻译 API")
        case .installed: break
        @unknown default:
            throw ActionError.translationFailed("暂时无法确认翻译语言包状态，请稍后重试")
        }
        let session = backend.session(source: source, target: target)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let result = try await session.translate(sourceText)
                try Task.checkCancellation()
                return result
            } catch TranslationError.notInstalled {
                throw ActionError.translationFailed("请先下载翻译语言包，再重试系统翻译")
            }
        } onCancel: {
            // Each request owns its session, so cancelling one draft cannot stop another.
            Task { @MainActor in session.cancel() }
        }
    }
}

@MainActor
private struct AppleTranslationBackend: SystemTranslationBackend {
    func availability(source: String, target: String) async -> LanguageAvailability.Status {
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
        else { availability = LanguageAvailability() }
        return await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    }
    func session(source: String, target: String) -> any SystemTranslationSession {
        AppleTranslationSession(source: source, target: target)
    }
}

@MainActor
private final class AppleTranslationSession: SystemTranslationSession {
    private let session: TranslationSession
    init(source: String, target: String) {
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: Locale.Language(identifier: source),
                target: Locale.Language(identifier: target), preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        }
    }
    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }
    func cancel() { session.cancel() }
}
