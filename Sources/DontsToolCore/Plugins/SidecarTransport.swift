import Darwin
import Foundation

public enum PluginTransportError: LocalizedError, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case cancelled
    case outputTooLarge
    case invalidResponse(String)
    case processExited(status: Int32, stderr: String)
    case rpcError(code: Int, message: String)
    case crashLoop

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): "无法启动插件进程：\(detail)"
        case .timedOut: "插件响应超时"
        case .cancelled: "插件请求已取消"
        case .outputTooLarge: "插件单次输出超过大小限制"
        case .invalidResponse(let detail): "插件返回格式无效：\(detail)"
        case .processExited(let status, let stderr):
            stderr.isEmpty ? "插件进程异常退出（\(status)）" : "插件进程异常退出：\(stderr)"
        case .rpcError(_, let message): message
        case .crashLoop: "插件连续崩溃，已暂停自动重启"
        }
    }
}

public protocol PluginTransport: Sendable {
    func request(method: String, paramsData: Data, timeout: Duration) async throws -> Data
    func shutdown() async
    func shutdownSync()
}

private enum SidecarConstants {
    static let maxOutputBytes = 1_048_576
    static let maxStderrBytes = 8_192
}

private enum SidecarWire {
    static func encodeRequest(id: Int, method: String, paramsData: Data) throws -> Data {
        let methodJSON = try JSONEncoder().encode(method)
        var line = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":".utf8)
        line.append(methodJSON)
        line.append(contentsOf: ",\"params\":".utf8)
        line.append(paramsData.isEmpty ? Data("{}".utf8) : paramsData)
        line.append(contentsOf: "}\n".utf8)
        return line
    }

    static func encodeNotification(method: String, paramsData: Data) throws -> Data {
        let methodJSON = try JSONEncoder().encode(method)
        var line = Data("{\"jsonrpc\":\"2.0\",\"method\":".utf8)
        line.append(methodJSON)
        line.append(contentsOf: ",\"params\":".utf8)
        line.append(paramsData.isEmpty ? Data("{}".utf8) : paramsData)
        line.append(contentsOf: "}\n".utf8)
        return line
    }

    static func makeEnvironment(for manifest: ResolvedPluginManifest) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DONTSTOOL_HOST_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["DONTSTOOL_PLUGIN_ID"] = manifest.id
        env["DONTSTOOL_PLUGIN_DIR"] = manifest.directoryURL.path
        return env
    }

    static func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    static func disableSigpipe(on handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    static func extractFirstNonEmptyLine(from data: Data) -> Data? {
        for rawLine in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var line = Data(rawLine)
            if line.last == UInt8(ascii: "\r") {
                line.removeLast()
            }
            if line.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }) {
                return line
            }
        }
        return nil
    }
}

// MARK: - Oneshot Transport

public final class OneShotSidecarTransport: PluginTransport, @unchecked Sendable {
    private let manifest: ResolvedPluginManifest
    private let lock = NSLock()
    private var isStopped = false
    private var activeProcesses: [UUID: Process] = [:]

    public init(manifest: ResolvedPluginManifest) {
        self.manifest = manifest
    }

    public func request(method: String, paramsData: Data, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        guard !stoppedFlag else { throw PluginTransportError.cancelled }

        let requestLine = try SidecarWire.encodeRequest(id: 1, method: method, paramsData: paramsData)
        let process = Process()
        process.executableURL = manifest.executableURL
        process.arguments = manifest.arguments
        process.currentDirectoryURL = manifest.directoryURL
        process.environment = SidecarWire.makeEnvironment(for: manifest)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        SidecarWire.disableSigpipe(on: stdinPipe.fileHandleForWriting)

        let runID = UUID()
        let session = OneShotSession()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let exceeded = session.appendStdout(chunk)
            if exceeded {
                handle.readabilityHandler = nil
                SidecarWire.terminateProcess(process)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            session.appendStderr(chunk)
        }

        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                if self.stoppedFlag || Task.isCancelled {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: PluginTransportError.cancelled)
                    return
                }

                session.installContinuation(continuation)

                process.terminationHandler = { [weak self] finished in
                    self?.unregister(runID)
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    if let remainingOut = try? stdoutPipe.fileHandleForReading.readToEnd(), !remainingOut.isEmpty {
                        _ = session.appendStdout(remainingOut)
                    }
                    if let remainingErr = try? stderrPipe.fileHandleForReading.readToEnd(), !remainingErr.isEmpty {
                        session.appendStderr(remainingErr)
                    }

                    let (stdoutData, stderrData, statusFlags) = session.snapshot()
                    if statusFlags.cancelled {
                        session.finish(.failure(PluginTransportError.cancelled))
                        return
                    }
                    if statusFlags.outputTooLarge {
                        session.finish(.failure(PluginTransportError.outputTooLarge))
                        return
                    }
                    if statusFlags.timedOut {
                        session.finish(.failure(PluginTransportError.timedOut))
                        return
                    }

                    guard let line = SidecarWire.extractFirstNonEmptyLine(from: stdoutData) else {
                        let stderrText = String(decoding: stderrData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        session.finish(.failure(PluginTransportError.processExited(
                            status: finished.terminationStatus,
                            stderr: stderrText
                        )))
                        return
                    }

                    do {
                        let envelope = try JSONDecoder().decode(PluginRPCEnvelope.self, from: line)
                        if let error = envelope.error {
                            session.finish(.failure(PluginTransportError.rpcError(code: error.code, message: error.message)))
                            return
                        }
                        session.finish(.success(line))
                    } catch {
                        session.finish(.failure(PluginTransportError.invalidResponse(error.localizedDescription)))
                    }
                }

                do {
                    self.register(process, id: runID)
                    try process.run()
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: requestLine)
                    try? stdinPipe.fileHandleForWriting.close()
                    if Task.isCancelled {
                        session.markCancelled()
                        SidecarWire.terminateProcess(process)
                        session.finish(.failure(PluginTransportError.cancelled))
                        return
                    }
                } catch {
                    self.unregister(runID)
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    session.finish(.failure(PluginTransportError.launchFailed(error.localizedDescription)))
                    return
                }

                Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard process.isRunning else { return }
                    session.markTimedOut()
                    SidecarWire.terminateProcess(process)
                    session.finish(.failure(PluginTransportError.timedOut))
                }
            }
        } onCancel: {
            session.markCancelled()
            SidecarWire.terminateProcess(process)
            session.finish(.failure(PluginTransportError.cancelled))
        }

        try Task.checkCancellation()
        return responseData
    }

    public func shutdown() async {
        shutdownSync()
    }

    public func shutdownSync() {
        let processes: [Process] = lock.withLock {
            isStopped = true
            let list = Array(activeProcesses.values)
            activeProcesses.removeAll()
            return list
        }
        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    private var stoppedFlag: Bool {
        lock.withLock { isStopped }
    }

    private func register(_ process: Process, id: UUID) {
        lock.withLock {
            activeProcesses[id] = process
        }
    }

    private func unregister(_ id: UUID) {
        lock.withLock {
            _ = activeProcesses.removeValue(forKey: id)
        }
    }
}

private final class OneShotSession: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var timedOut = false
    private var cancelled = false
    private var outputTooLarge = false
    private var finished = false
    private var continuation: CheckedContinuation<Data, Error>?

    func installContinuation(_ continuation: CheckedContinuation<Data, Error>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    @discardableResult
    func appendStdout(_ chunk: Data) -> Bool {
        lock.withLock {
            guard !outputTooLarge else { return true }
            if stdoutData.count + chunk.count > SidecarConstants.maxOutputBytes {
                outputTooLarge = true
                return true
            }
            stdoutData.append(chunk)
            return false
        }
    }

    func appendStderr(_ chunk: Data) {
        lock.withLock {
            guard stderrData.count < SidecarConstants.maxStderrBytes else { return }
            let remaining = SidecarConstants.maxStderrBytes - stderrData.count
            stderrData.append(chunk.prefix(remaining))
        }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }

    func markCancelled() {
        lock.withLock { cancelled = true }
    }

    func snapshot() -> (Data, Data, (timedOut: Bool, cancelled: Bool, outputTooLarge: Bool)) {
        lock.withLock {
            (stdoutData, stderrData, (timedOut, cancelled, outputTooLarge))
        }
    }

    func finish(_ result: Result<Data, Error>) {
        let cont: CheckedContinuation<Data, Error>? = lock.withLock {
            guard !finished, let current = continuation else { return nil }
            finished = true
            continuation = nil
            return current
        }
        cont?.resume(with: result)
    }
}

// MARK: - Daemon Transport

public actor DaemonSidecarTransport: PluginTransport {
    private let manifest: ResolvedPluginManifest
    private let processBox = LockedProcessBox()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var idleTask: Task<Void, Never>?
    private var isStopped = false
    private var isExpectedShutdown = false
    private var recentCrashTimestamps: [Date] = []
    private var lastStderr = BoundedDataBuffer(limit: SidecarConstants.maxStderrBytes)

    public init(manifest: ResolvedPluginManifest) {
        self.manifest = manifest
    }

    public func request(method: String, paramsData: Data, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        guard !isStopped, !processBox.isStopped else {
            throw PluginTransportError.cancelled
        }

        idleTask?.cancel()
        idleTask = nil

        try ensureRunning()
        guard let writeHandle = stdinHandle else {
            throw PluginTransportError.launchFailed("无法打开插件输入管道")
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let lineData = try SidecarWire.encodeRequest(id: requestID, method: method, paramsData: paramsData)

        defer { scheduleIdleShutdownIfNeeded() }

        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeoutRequest(id: requestID)
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                if isStopped || processBox.isStopped || Task.isCancelled {
                    continuation.resume(throwing: PluginTransportError.cancelled)
                    return
                }
                pending[requestID] = continuation
                do {
                    try writeHandle.write(contentsOf: lineData)
                } catch {
                    pending.removeValue(forKey: requestID)
                    teardownProcess(expected: false)
                    continuation.resume(throwing: PluginTransportError.processExited(
                        status: -1,
                        stderr: error.localizedDescription
                    ))
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(id: requestID)
            }
        }
    }

    public func shutdown() async {
        isStopped = true
        processBox.markStopped()
        idleTask?.cancel()
        idleTask = nil
        failAllPending(with: PluginTransportError.cancelled)

        guard let running = process, running.isRunning else {
            teardownProcess(expected: true)
            return
        }

        isExpectedShutdown = true
        if let handle = stdinHandle,
           let payload = try? JSONEncoder().encode(PluginEmptyParams()),
           let note = try? SidecarWire.encodeNotification(method: "shutdown", paramsData: payload) {
            try? handle.write(contentsOf: note)
        }
        try? stdinHandle?.close()
        stdinHandle = nil

        try? await Task.sleep(for: .milliseconds(150))
        if running.isRunning {
            SidecarWire.terminateProcess(running)
        }
        teardownProcess(expected: true)
    }

    nonisolated public func shutdownSync() {
        processBox.shutdownImmediately()
    }

    // MARK: - Internals

    private func ensureRunning() throws {
        if let current = process, current.isRunning, stdinHandle != nil {
            return
        }

        let now = Date()
        recentCrashTimestamps = recentCrashTimestamps.filter { now.timeIntervalSince($0) < 5 }
        if recentCrashTimestamps.count >= 3 {
            throw PluginTransportError.crashLoop
        }

        let next = Process()
        next.executableURL = manifest.executableURL
        next.arguments = manifest.arguments
        next.currentDirectoryURL = manifest.directoryURL
        next.environment = SidecarWire.makeEnvironment(for: manifest)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        next.standardInput = stdinPipe
        next.standardOutput = stdoutPipe
        next.standardError = stderrPipe
        SidecarWire.disableSigpipe(on: stdinPipe.fileHandleForWriting)

        lastStderr.clear()
        let stderrCapture = lastStderr
        let pluginID = manifest.id
        let lineReader = LineStreamReader(maxLineBytes: SidecarConstants.maxOutputBytes)

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                let trailing = lineReader.drainTrailing()
                Task { [weak self] in
                    if let trailing {
                        await self?.handleStdoutLine(trailing)
                    }
                    await self?.handleStdoutEOF(for: next)
                }
                return
            }

            let outcome = lineReader.append(chunk)
            if outcome.exceededLimit {
                handle.readabilityHandler = nil
                Task { [weak self] in
                    await self?.handleOutputOverflow(for: next)
                }
                return
            }
            if !outcome.lines.isEmpty {
                Task { [weak self] in
                    for line in outcome.lines {
                        await self?.handleStdoutLine(line)
                    }
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrCapture.append(chunk)
            let text = String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                Log.plugin.debug("[\(pluginID, privacy: .public)] \(text, privacy: .private)")
            }
        }

        next.terminationHandler = { [weak self] terminated in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Task { [weak self] in
                await self?.handleProcessTerminated(terminated)
            }
        }

        do {
            try next.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw PluginTransportError.launchFailed(error.localizedDescription)
        }

        isExpectedShutdown = false
        process = next
        stdinHandle = stdinPipe.fileHandleForWriting
        processBox.set(next)
    }

    private func handleStdoutLine(_ line: Data) {
        guard !line.isEmpty else { return }
        do {
            let envelope = try JSONDecoder().decode(PluginRPCEnvelope.self, from: line)
            guard let id = envelope.id else { return }
            if let error = envelope.error {
                finishRequest(id: id, result: .failure(PluginTransportError.rpcError(code: error.code, message: error.message)))
            } else {
                finishRequest(id: id, result: .success(line))
            }
        } catch {
            Log.plugin.warning("插件 \(self.manifest.id, privacy: .public) 返回无法解析的 JSON 行")
        }
    }

    private func handleOutputOverflow(for target: Process) {
        guard process === target else { return }
        failAllPending(with: PluginTransportError.outputTooLarge)
        teardownProcess(expected: false)
    }

    private func handleStdoutEOF(for target: Process) {
        guard process === target else { return }
        handleUnexpectedExit(status: target.isRunning ? -1 : target.terminationStatus)
    }

    private func handleProcessTerminated(_ target: Process) {
        guard process === target else { return }
        handleUnexpectedExit(status: target.terminationStatus)
    }

    private func handleUnexpectedExit(status: Int32) {
        let wasExpected = isExpectedShutdown || isStopped || processBox.isStopped
        if !wasExpected {
            recentCrashTimestamps.append(Date())
        }
        let errText = String(decoding: lastStderr.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        failAllPending(with: wasExpected
            ? PluginTransportError.cancelled
            : PluginTransportError.processExited(status: status, stderr: errText))
        teardownProcess(expected: wasExpected)
    }

    private func timeoutRequest(id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: PluginTransportError.timedOut)
        // Reset wedged daemon so subsequent searches start clean instead of hanging behind it.
        teardownProcess(expected: true)
    }

    private func cancelRequest(id: Int) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: PluginTransportError.cancelled)
        }
        if let handle = stdinHandle,
           let payload = try? JSONEncoder().encode(PluginCancelParams(id: id)),
           let note = try? SidecarWire.encodeNotification(method: "cancel", paramsData: payload) {
            try? handle.write(contentsOf: note)
        }
    }

    private func finishRequest(id: Int, result: Result<Data, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAllPending(with error: Error) {
        let remaining = pending
        pending.removeAll()
        for continuation in remaining.values {
            continuation.resume(throwing: error)
        }
    }

    private func scheduleIdleShutdownIfNeeded() {
        idleTask?.cancel()
        idleTask = nil
        guard pending.isEmpty, !isStopped, let running = process, running.isRunning else { return }
        let delay = manifest.idleTimeout
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.performIdleShutdown()
        }
    }

    private func performIdleShutdown() {
        guard pending.isEmpty else { return }
        isExpectedShutdown = true
        if let handle = stdinHandle,
           let payload = try? JSONEncoder().encode(PluginEmptyParams()),
           let note = try? SidecarWire.encodeNotification(method: "shutdown", paramsData: payload) {
            try? handle.write(contentsOf: note)
        }
        try? stdinHandle?.close()
        stdinHandle = nil
        if let running = process, running.isRunning {
            SidecarWire.terminateProcess(running)
        }
        process = nil
        processBox.set(nil)
    }

    private func teardownProcess(expected: Bool) {
        isExpectedShutdown = expected
        try? stdinHandle?.close()
        stdinHandle = nil
        if let current = process {
            if current.isRunning {
                SidecarWire.terminateProcess(current)
            }
        }
        process = nil
        processBox.set(nil)
    }
}

private final class LockedProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?
    private var stopped = false

    var isStopped: Bool {
        lock.withLock { stopped }
    }

    func set(_ process: Process?) {
        lock.withLock { current = process }
    }

    func markStopped() {
        lock.withLock { stopped = true }
    }

    func shutdownImmediately() {
        let proc: Process? = lock.withLock {
            stopped = true
            let target = current
            current = nil
            return target
        }
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }
}

private final class BoundedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data {
        lock.withLock { storage }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            guard storage.count < limit else { return }
            storage.append(chunk.prefix(limit - storage.count))
        }
    }

    func clear() {
        lock.withLock { storage.removeAll(keepingCapacity: false) }
    }
}

private final class LineStreamReader: @unchecked Sendable {
    private let lock = NSLock()
    private let maxLineBytes: Int
    private var buffer = Data()

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    func append(_ chunk: Data) -> (lines: [Data], exceededLimit: Bool) {
        lock.withLock {
            buffer.append(chunk)
            var lines: [Data] = []
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                if line.count > maxLineBytes {
                    buffer.removeAll(keepingCapacity: false)
                    return ([], true)
                }
                if line.last == UInt8(ascii: "\r") {
                    line.removeLast()
                }
                if line.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }) {
                    lines.append(line)
                }
            }
            if buffer.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                return ([], true)
            }
            return (lines, false)
        }
    }

    func drainTrailing() -> Data? {
        lock.withLock {
            defer { buffer.removeAll(keepingCapacity: false) }
            guard !buffer.isEmpty, buffer.count <= maxLineBytes else { return nil }
            var line = buffer
            if line.last == UInt8(ascii: "\r") {
                line.removeLast()
            }
            return line.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }) ? line : nil
        }
    }
}
