import Foundation

/// Update installation and a concurrent system quit share the same save operation.
@MainActor
public final class TerminationPreparation {
    private let prepare: @MainActor () async -> Bool
    private var active: Task<Bool, Never>?

    public init(prepare: @escaping @MainActor () async -> Bool) { self.prepare = prepare }

    public func run() async -> Bool {
        if let active { return await active.value }
        let task = Task { await prepare() }
        active = task
        let result = await task.value
        active = nil
        return result
    }
}
