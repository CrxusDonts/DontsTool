import AppKit
import Darwin
import Foundation
import os

public struct RunningAppSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let localizedName: String?
    public let bundlePath: String?
    public let isRegularApp: Bool

    public init(pid: Int32, localizedName: String?, bundlePath: String?, isRegularApp: Bool) {
        self.pid = pid
        self.localizedName = localizedName
        self.bundlePath = bundlePath
        self.isRegularApp = isRegularApp
    }
}

public final class SystemProcessService: ProcessControlling, Sendable {
    public init() {}

    public func listProcesses() async throws -> [RunningProcess] {
        let currentUID = getuid()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let appsByPID = await MainActor.run { Self.snapshotRunningApps() }

        let (commOutput, argsOutput) = try await Task.detached(priority: .userInitiated) {
            let comm = try Self.runCommand(
                executablePath: "/bin/ps",
                arguments: ["-axo", "pid=,ppid=,uid=,%cpu=,rss=,comm="],
                timeout: .seconds(2)
            )
            let args = (try? Self.runCommand(
                executablePath: "/bin/ps",
                arguments: ["-axo", "pid=,args="],
                timeout: .seconds(2)
            )) ?? ""
            return (comm, args)
        }.value

        return Self.parsePSOutput(
            commOutput: commOutput,
            argsOutput: argsOutput,
            currentUID: currentUID,
            currentPID: currentPID,
            appsByPID: appsByPID
        )
    }

    public func listeningPIDs(onPort port: UInt16) async throws -> Set<Int32> {
        let output = try await Task.detached(priority: .userInitiated) {
            try Self.runCommand(
                executablePath: "/usr/sbin/lsof",
                arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"],
                timeout: .seconds(2),
                allowNonZeroExit: true
            )
        }.value
        return Self.parseLsofPIDs(output)
    }

    public func terminate(pid: Int32, signal: ProcessTerminationSignal) async throws {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard pid > 1, pid != currentPID else {
            throw ProcessControlError.protectedProcess("PID \(pid)")
        }

        if signal == .terminate {
            let terminatedByAppKit = await MainActor.run { () -> Bool in
                guard let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular else {
                    return false
                }
                return app.terminate()
            }
            if terminatedByAppKit {
                return
            }
        } else {
            let forceTerminated = await MainActor.run { () -> Bool in
                guard let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular else {
                    return false
                }
                return app.forceTerminate()
            }
            if forceTerminated {
                return
            }
        }

        let posixSignal = signal == .terminate ? SIGTERM : SIGKILL
        if Darwin.kill(pid, posixSignal) != 0 {
            let code = errno
            switch code {
            case EPERM:
                throw ProcessControlError.permissionDenied(pid: pid)
            case ESRCH:
                throw ProcessControlError.notFound(pid: pid)
            default:
                throw ProcessControlError.failed(pid: pid, code: code)
            }
        }
    }

    public func killAll(named name: String, excludingPID: Int32, signal: ProcessTerminationSignal) async throws -> Int {
        let processes = try await listProcesses()
        let matches = processes.filter {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame && $0.pid != excludingPID && $0.pid > 1
        }
        var killed = 0
        var lastError: (any Error)?
        for process in matches {
            do {
                try await terminate(pid: process.pid, signal: signal)
                killed += 1
            } catch ProcessControlError.notFound {
                continue
            } catch {
                lastError = error
            }
        }
        if killed == 0, let lastError {
            throw lastError
        }
        return killed
    }

    // MARK: - Parsing

    public static func parsePSOutput(
        commOutput: String,
        argsOutput: String,
        currentUID: UInt32,
        currentPID: Int32,
        appsByPID: [Int32: RunningAppSnapshot]
    ) -> [RunningProcess] {
        var argsByPID: [Int32: String] = [:]
        for line in argsOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: \.isWhitespace)
            guard let spaceIndex = trimmed.firstIndex(where: \.isWhitespace),
                  let pid = Int32(trimmed[..<spaceIndex]) else { continue }
            let command = trimmed[spaceIndex...].drop(while: \.isWhitespace)
            if !command.isEmpty {
                argsByPID[pid] = String(command)
            }
        }

        var results: [RunningProcess] = []
        for rawLine in commOutput.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.drop(while: \.isWhitespace)
            guard !trimmed.isEmpty else { continue }
            let fields = splitFixedFields(trimmed, count: 5)
            guard fields.count == 6,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let uid = UInt32(fields[2]),
                  let cpu = Double(fields[3]),
                  let rssKiB = UInt64(fields[4]) else { continue }

            guard pid > 1, pid != currentPID, uid == currentUID else { continue }

            let commPath = String(fields[5]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commPath.isEmpty else { continue }

            let app = appsByPID[pid]
            let fallbackName = URL(fileURLWithPath: commPath).lastPathComponent
            let displayName: String
            if let localized = app?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !localized.isEmpty {
                displayName = localized
            } else {
                displayName = fallbackName.isEmpty ? commPath : fallbackName
            }

            let bundlePath = app?.bundlePath ?? Self.enclosingAppBundlePath(for: commPath)
            let commandLine = argsByPID[pid] ?? commPath

            results.append(RunningProcess(
                pid: pid,
                parentPID: ppid,
                uid: uid,
                name: displayName,
                executablePath: commPath,
                commandLine: commandLine,
                appBundlePath: bundlePath,
                cpuPercent: max(0, cpu),
                memoryBytes: rssKiB * 1024,
                isApplication: app?.isRegularApp ?? false
            ))
        }
        return results
    }

    public static func parseLsofPIDs(_ output: String) -> Set<Int32> {
        var pids: Set<Int32> = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.first == "p", let pid = Int32(line.dropFirst()), pid > 1 else { continue }
            pids.insert(pid)
        }
        return pids
    }

    static func enclosingAppBundlePath(for executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        let candidate = String(executablePath[..<range.upperBound].dropLast())
        return candidate.hasPrefix("/") ? candidate : nil
    }

    private static func splitFixedFields(_ line: Substring, count: Int) -> [Substring] {
        var parts: [Substring] = []
        parts.reserveCapacity(count + 1)
        var cursor = line.startIndex
        for _ in 0..<count {
            while cursor < line.endIndex, line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            guard cursor < line.endIndex else { return parts }
            let start = cursor
            while cursor < line.endIndex, !line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            parts.append(line[start..<cursor])
        }
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        if cursor < line.endIndex {
            parts.append(line[cursor..<line.endIndex])
        }
        return parts
    }

    @MainActor
    private static func snapshotRunningApps() -> [Int32: RunningAppSnapshot] {
        var map: [Int32: RunningAppSnapshot] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 1 else { continue }
            map[pid] = RunningAppSnapshot(
                pid: pid,
                localizedName: app.localizedName,
                bundlePath: app.bundleURL?.path,
                isRegularApp: app.activationPolicy == .regular
            )
        }
        return map
    }

    private static func runCommand(
        executablePath: String,
        arguments: [String],
        timeout: Duration,
        allowNonZeroExit: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ProcessControlError.listFailed(error.localizedDescription)
        }

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        if timedOut.withLock({ $0 }) {
            throw ProcessControlError.listFailed("命令执行超时")
        }
        if !allowNonZeroExit && process.terminationStatus != 0 {
            let errText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessControlError.listFailed(errText.isEmpty ? "exit \(process.terminationStatus)" : errText)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
