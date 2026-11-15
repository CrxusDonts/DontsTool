import AppKit

@MainActor
public protocol IDEProjectOpening: AnyObject {
    func openProject(at project: URL, using application: URL) async throws
    func revealInFinder(_ url: URL)
}

@MainActor
public final class SystemIDEProjectLauncher: IDEProjectOpening {
    public init() {}

    public func openProject(at project: URL, using application: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [project.path]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
