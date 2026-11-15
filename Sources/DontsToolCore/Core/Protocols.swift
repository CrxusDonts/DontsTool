import Foundation

@MainActor
public protocol ClipboardProviding: AnyObject {
    func readString() -> String?
    func writeString(_ string: String)
}

@MainActor
public protocol FeedbackProviding: AnyObject {
    func show(_ message: String)
}

@MainActor
public protocol OperationProgressReporting: AnyObject {
    func begin(_ message: String)
    func end()
}

@MainActor
public protocol AppLaunching: AnyObject {
    func openApplication(at url: URL) async throws
    func openFile(at url: URL) throws
    func revealInFinder(_ url: URL)
    func quitApplication(at url: URL) -> Bool
}

@MainActor
public protocol URLOpening: AnyObject {
    func open(_ url: URL) throws
}

@MainActor
public protocol QueryPrefilling: AnyObject {
    func prefill(_ query: String)
}

@MainActor
public protocol SettingsOpening: AnyObject {
    func openSettings()
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult
}

public struct CommandResult: Sendable {
    public let output: String
    public let terminationStatus: Int32
    public let timedOut: Bool

    public init(output: String, terminationStatus: Int32, timedOut: Bool) {
        self.output = output
        self.terminationStatus = terminationStatus
        self.timedOut = timedOut
    }
}

public enum ActionError: LocalizedError, Equatable, Sendable {
    case clipboardEmpty
    case invalidInput(String)
    case openFailed(String)
    case commandFailed(String)
    case translationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .clipboardEmpty: "剪贴板为空"
        case .invalidInput(let message): message
        case .openFailed(let target): "无法打开\(target)"
        case .commandFailed(let message): message
        case .translationFailed(let message): message
        }
    }
}
