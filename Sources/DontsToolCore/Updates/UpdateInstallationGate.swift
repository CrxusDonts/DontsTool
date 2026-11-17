import Combine
import Foundation

/// Keeps Sparkle's installation callback pending until every document agrees to close.
@MainActor
public final class UpdateInstallationGate: ObservableObject {
    @Published public private(set) var hasPendingInstallation = false
    @Published public private(set) var isPreparing = false
    private let prepare: @MainActor () async -> Bool
    private var install: (@MainActor () -> Void)?

    public init(prepare: @escaping @MainActor () async -> Bool) {
        self.prepare = prepare
    }

    public func postpone(_ install: @escaping @MainActor () -> Void) {
        guard self.install == nil else { return }
        self.install = install
        hasPendingInstallation = true
    }

    public func resume() async {
        guard !isPreparing, let install else { return }
        isPreparing = true
        defer { isPreparing = false }
        guard !Task.isCancelled, await prepare(), !Task.isCancelled else { return }
        self.install = nil
        hasPendingInstallation = false
        install()
    }
}
