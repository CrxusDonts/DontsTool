import Foundation
import Testing
@testable import DontsToolCore

final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    var result: CommandResult!
    var error: Error?
    var receivedArguments: [String] = []

    func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult {
        receivedArguments = arguments
        if let error { throw error }
        return result
    }
}

@Suite("FileSearchService")
struct FileSearchServiceTests {
    @Test func filtersSystemHiddenAndAppPaths() async throws {
        let runner = MockCommandRunner()
        runner.result = CommandResult(
            output: """
            /Users/donts/Desktop/report.pdf
            /System/Library/foo.txt
            /Users/donts/.secret/hidden.txt
            /Users/donts/Desktop/Report.app
            /private/tmp/x.txt
            """,
            terminationStatus: 0,
            timedOut: false
        )
        let service = FileSearchService(runner: runner)
        let result = try await service.search(query: "report", timeout: .milliseconds(300))
        #expect(result.paths.map(\.lastPathComponent) == ["report.pdf"])
        #expect(Array(runner.receivedArguments.prefix(2)) == ["-name", "report"])
        #expect(runner.receivedArguments.contains("-onlyin"))
    }

    @Test func ranksMatchesAndCapsAtTwelve() async throws {
        let runner = MockCommandRunner()
        let lines = (0..<20).map { "/Users/donts/Desktop/report-\($0).txt" }.joined(separator: "\n")
        runner.result = CommandResult(output: lines, terminationStatus: 0, timedOut: false)
        let service = FileSearchService(runner: runner)
        let result = try await service.search(query: "report", timeout: .milliseconds(300))
        #expect(result.paths.count == 12)
    }

    @Test func timedOutReturnsPartialResults() async throws {
        let runner = MockCommandRunner()
        runner.result = CommandResult(
            output: "/Users/donts/Desktop/partial.txt\n",
            terminationStatus: 15,
            timedOut: true
        )
        let service = FileSearchService(runner: runner)
        let result = try await service.search(query: "partial", timeout: .milliseconds(300))
        #expect(result.paths.map(\.lastPathComponent) == ["partial.txt"])
        #expect(result.timedOut)
    }

    @Test func commandFailureThrows() async {
        let runner = MockCommandRunner()
        runner.result = CommandResult(output: "", terminationStatus: 1, timedOut: false)
        let service = FileSearchService(runner: runner)
        await #expect(throws: (any Error).self) {
            try await service.search(query: "x", timeout: .milliseconds(300))
        }
    }

    @Test func hitsCarryFuzzyScoresForProviderUse() async throws {
        let runner = MockCommandRunner()
        runner.result = CommandResult(
            output: """
            /Users/donts/Desktop/report.pdf
            /Users/donts/Desktop/xreport.txt
            """,
            terminationStatus: 0,
            timedOut: false
        )
        let service = FileSearchService(runner: runner)
        let result = try await service.search(query: "rep", timeout: .milliseconds(300))
        #expect(result.hits.count == 2)
        #expect(result.hits[0].score >= result.hits[1].score)
    }
}

@Suite("ProcessCommandRunner")
struct ProcessCommandRunnerTests {
    @Test func alreadyCancelledTaskNeverStartsTheCommand() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-command-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessCommandRunner().run(executable: "/usr/bin/touch", arguments: [marker.path], timeout: .seconds(2))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func timeoutKillsACommandThatIgnoresTerminateAndInterrupt() async throws {
        let start = ContinuousClock.now
        let result = try await ProcessCommandRunner().run(executable: "/usr/bin/python3", arguments: [
            "-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); signal.signal(signal.SIGINT,signal.SIG_IGN); time.sleep(4)"
        ], timeout: .milliseconds(250))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func cancellationTerminatesAnActiveCommandAndThrowsCancellation() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("running-command-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await ProcessCommandRunner().run(executable: "/usr/bin/python3", arguments: [
                "-c", "import sys,signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); signal.signal(signal.SIGINT,signal.SIG_IGN); pathlib.Path(sys.argv[1]).touch(); time.sleep(4)", marker.path
            ], timeout: .seconds(10))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(2))
    }
    @Test func capturesStandardOutput() async throws {
        let result = try await ProcessCommandRunner().run(
            executable: "/bin/echo",
            arguments: ["hello"],
            timeout: .seconds(2)
        )
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(result.terminationStatus == 0)
        #expect(!result.timedOut)
    }

    @Test func terminatesOnTimeout() async throws {
        let start = ContinuousClock.now
        let result = try await ProcessCommandRunner().run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: .milliseconds(200)
        )
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let result = try await ProcessCommandRunner().run(
            executable: "/usr/bin/yes",
            arguments: ["x"],
            timeout: .milliseconds(300)
        )
        #expect(result.timedOut)
        #expect(result.output.count > 10_000)
    }
}
