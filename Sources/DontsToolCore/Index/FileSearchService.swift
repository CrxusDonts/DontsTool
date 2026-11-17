import Foundation
import Darwin

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        let buffer = OutputBuffer()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(data)
        }

        let state = CommandState()
        let box = ProcessBox(process)

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    if let pipe = finished.standardOutput as? Pipe {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        if let remaining = try? pipe.fileHandleForReading.readToEnd() {
                            buffer.append(remaining)
                        }
                    }
                    state.finish(
                        with: CommandResult(
                            output: String(decoding: buffer.data, as: UTF8.self),
                            terminationStatus: finished.terminationStatus,
                            timedOut: state.timedOut
                        ),
                        continuation: continuation
                    )
                }

                do {
                    try Task.checkCancellation()
                    try process.run()
                    // Cancellation may have arrived between the preflight check and launch.
                    if Task.isCancelled { box.terminate() }
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    state.finish(with: error, continuation: continuation)
                    return
                }

                Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    let process = box.process
                    guard process.isRunning else { return }
                    state.markTimedOut()
                    box.terminate()
                }
            }
        } onCancel: {
            box.terminate()
        }
        try Task.checkCancellation()
        return result
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        Task.detached { [self] in
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
    }
}

private final class CommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timedOutFlag = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }

    func markTimedOut() {
        lock.lock()
        defer { lock.unlock() }
        timedOutFlag = true
    }

    func finish(with result: CommandResult, continuation: CheckedContinuation<CommandResult, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume(returning: result)
    }

    func finish(with error: Error, continuation: CheckedContinuation<CommandResult, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

public struct FileSearchHit: Sendable, Equatable {
    public let url: URL
    public let score: Double

    public init(url: URL, score: Double) {
        self.url = url
        self.score = score
    }
}

public struct FileSearchResult: Sendable {
    public let hits: [FileSearchHit]
    public let timedOut: Bool

    public init(hits: [FileSearchHit], timedOut: Bool) {
        self.hits = hits
        self.timedOut = timedOut
    }

    public var paths: [URL] {
        hits.map(\.url)
    }
}

public struct FileSearchService: Sendable {
    private let runner: any CommandRunning
    private let searchRoot: URL

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        searchRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.runner = runner
        self.searchRoot = searchRoot
    }

    public func search(query: String, timeout: Duration) async throws -> FileSearchResult {
        try Task.checkCancellation()
        // Keep Spotlight scoped to the user directory rather than querying the whole disk.
        let result = try await runner.run(
            executable: "/usr/bin/mdfind",
            arguments: ["-name", query, "-onlyin", searchRoot.path],
            timeout: timeout
        )
        try Task.checkCancellation()

        if result.output.isEmpty && result.terminationStatus != 0 && !result.timedOut {
            throw ActionError.commandFailed("文件搜索不可用")
        }

        let excludedPrefixes = ["/System/", "/Library/", "/private/", "/Users/Shared/"]
        var seen: Set<String> = []
        var hits: [FileSearchHit] = []

        for line in result.output.split(whereSeparator: \.isNewline) {
            let path = String(line)
            guard !path.isEmpty,
                  !excludedPrefixes.contains(where: { path.hasPrefix($0) }),
                  !path.hasSuffix(".app"),
                  !path.contains(".app/") else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.pathComponents.dropFirst().allSatisfy({ !$0.hasPrefix(".") }) else { continue }
            guard seen.insert(url.path).inserted else { continue }

            guard let score = FuzzyMatcher.score(query: query, candidate: url.lastPathComponent) else {
                continue
            }
            hits.append(FileSearchHit(url: url, score: score))
            if hits.count >= 200 { break }
        }

        let top = hits
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            .prefix(12)

        return FileSearchResult(hits: Array(top), timedOut: result.timedOut)
    }
}
