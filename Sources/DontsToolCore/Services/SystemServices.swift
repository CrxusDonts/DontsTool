import AppKit

@MainActor
public final class SystemAppLauncher: AppLaunching {
    public init() {}

    public func openApplication(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func openFile(at url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw ActionError.openFailed(url.lastPathComponent)
        }
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func quitApplication(at url: URL) -> Bool {
        let target = url.standardizedFileURL
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL == target
        }) else { return false }
        return application.terminate()
    }
}

@MainActor
public final class SystemClipboard: ClipboardProviding {
    public init() {}

    public func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    public func writeString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

@MainActor
public final class SystemURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw ActionError.openFailed(url.absoluteString)
        }
    }
}
