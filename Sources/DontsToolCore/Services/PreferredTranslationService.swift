import Foundation

/// A complete user API configuration takes precedence. Its failures never switch providers.
@MainActor
public final class PreferredTranslationService: TranslationServicing {
    private let remote: any TranslationServicing
    private let system: any TranslationServicing
    public init(remote: any TranslationServicing, system: any TranslationServicing) {
        self.remote = remote
        self.system = system
    }
    public var isConfigured: Bool { remote.isConfigured || system.isConfigured }
    public func translate(_ text: String, target: String) async throws -> String {
        try Task.checkCancellation()
        let service = remote.isConfigured ? remote : system
        let result = try await service.translate(text, target: target)
        try Task.checkCancellation()
        return result
    }
}
