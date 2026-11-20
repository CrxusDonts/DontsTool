import Foundation
import os
import Testing
@testable import DontsToolCore

private final class MockProcessService: ProcessControlling, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var processes: [RunningProcess] = []
        var portPIDs: [UInt16: Set<Int32>] = [:]
        var listCalls = 0
        var terminated: [(pid: Int32, signal: ProcessTerminationSignal)] = []
        var killedAll: [(name: String, signal: ProcessTerminationSignal)] = []
        var terminateError: (any Error)?
    }

    init(processes: [RunningProcess] = [], portPIDs: [UInt16: Set<Int32>] = [:]) {
        state = OSAllocatedUnfairLock(initialState: State(processes: processes, portPIDs: portPIDs))
    }

    var listCalls: Int { state.withLock(\.listCalls) }
    var terminated: [(pid: Int32, signal: ProcessTerminationSignal)] { state.withLock(\.terminated) }
    var killedAll: [(name: String, signal: ProcessTerminationSignal)] { state.withLock(\.killedAll) }

    func setTerminateError(_ error: (any Error)?) {
        state.withLock { $0.terminateError = error }
    }

    func listProcesses() async throws -> [RunningProcess] {
        state.withLock {
            $0.listCalls += 1
            return $0.processes
        }
    }

    func listeningPIDs(onPort port: UInt16) async throws -> Set<Int32> {
        state.withLock { $0.portPIDs[port] ?? [] }
    }

    func terminate(pid: Int32, signal: ProcessTerminationSignal) async throws {
        try state.withLock {
            if let error = $0.terminateError { throw error }
            $0.terminated.append((pid, signal))
            $0.processes.removeAll { $0.pid == pid }
        }
    }

    func killAll(named name: String, excludingPID: Int32, signal: ProcessTerminationSignal) async throws -> Int {
        try state.withLock {
            if let error = $0.terminateError { throw error }
            $0.killedAll.append((name, signal))
            let before = $0.processes.count
            $0.processes.removeAll {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame && $0.pid != excludingPID
            }
            return before - $0.processes.count
        }
    }
}

@MainActor
private final class MockProcessPrefill: QueryPrefilling {
    var prefilled: [String] = []
    func prefill(_ query: String) { prefilled.append(query) }
}

@Suite("Kill Process")
@MainActor
struct KillProcessTests {
    private func makeSettings() -> (SettingsStore, UserDefaults, String) {
        let name = "KillProcessTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        return (SettingsStore(defaults: defaults), defaults, name)
    }

    @Test func parsesMacOSPSOutputWithSpacesFiltersProtectedAndEnrichesAppBundles() {
        let comm = """
            1     0     0   0.0  18016 /sbin/launchd
          500     1   501   1.2  40960 /Applications/DontsTool.app/Contents/MacOS/DontsTool
          600     1   501  12.4 524288 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
          601   600   501   3.0 102400 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)
          700     1   501   0.5  65536 /opt/homebrew/bin/node
          800     1     0   0.2  20480 /usr/libexec/logd
        """
        let args = """
          600 /Applications/Visual Studio Code.app/Contents/MacOS/Electron --enable-features=foo
          700 /opt/homebrew/bin/node /Users/me/app/node_modules/.bin/vite --port 3000
        """
        let apps: [Int32: RunningAppSnapshot] = [
            600: RunningAppSnapshot(
                pid: 600,
                localizedName: "Visual Studio Code",
                bundlePath: "/Applications/Visual Studio Code.app",
                isRegularApp: true
            )
        ]

        let processes = SystemProcessService.parsePSOutput(
            commOutput: comm,
            argsOutput: args,
            currentUID: 501,
            currentPID: 500,
            appsByPID: apps
        )

        #expect(processes.map(\.pid) == [600, 601, 700])
        #expect(processes[0].name == "Visual Studio Code")
        #expect(processes[0].appBundlePath == "/Applications/Visual Studio Code.app")
        #expect(processes[0].isApplication)
        #expect(processes[0].formattedMemory == "512 MB")

        #expect(processes[1].name == "Code Helper (Renderer)")
        #expect(processes[1].appBundlePath == "/Applications/Visual Studio Code.app")
        #expect(!processes[1].isApplication)

        #expect(processes[2].name == "node")
        #expect(processes[2].commandLine.contains("vite --port 3000"))
        #expect(processes[2].appBundlePath == nil)
    }

    @Test func parsesLsofListeningPIDs() {
        let output = """
        p1234
        f20
        p5678
        p1234
        p1
        invalid
        """
        #expect(SystemProcessService.parseLsofPIDs(output) == [1234, 5678])
    }

    @Test func emptyGlobalQueryStaysSilentWhileChineseDiscoveryPrefillsKillKeyword() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MockProcessService()
        let prefill = MockProcessPrefill()
        let provider = KillProcessProvider(settings: settings, service: service, prefill: prefill)

        let emptyGlobal = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(emptyGlobal.isEmpty)
        #expect(service.listCalls == 0)

        let discovery = await provider.search(SearchContext(rawQuery: "结束进程", mode: .global))
        #expect(discovery.count == 1)
        #expect(discovery[0].title == "结束进程")
        try await discovery[0].primaryAction?.run()
        #expect(prefill.prefilled == ["kill "])
    }

    @Test func keywordSearchRanksByHotCPUAndMemoryAndMatchesPIDNameAndArgs() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let processes = [
            RunningProcess(pid: 101, name: "Finder", executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", appBundlePath: "/System/Library/CoreServices/Finder.app", cpuPercent: 1.0, memoryBytes: 150 * 1024 * 1024, isApplication: true),
            RunningProcess(pid: 202, name: "Google Chrome", executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", appBundlePath: "/Applications/Google Chrome.app", cpuPercent: 4.0, memoryBytes: 1_500 * 1024 * 1024, isApplication: true),
            RunningProcess(pid: 303, name: "node", executablePath: "/opt/homebrew/bin/node", commandLine: "node vite --port 5173", cpuPercent: 48.0, memoryBytes: 200 * 1024 * 1024),
            RunningProcess(pid: 304, name: "node", executablePath: "/opt/homebrew/bin/node", commandLine: "node worker.js", cpuPercent: 0.5, memoryBytes: 80 * 1024 * 1024)
        ]
        let service = MockProcessService(processes: processes)
        let provider = KillProcessProvider(settings: settings, service: service)

        // Default list boosts high CPU (>= 25%), then sorts by memory descending.
        let all = await provider.search(SearchContext(rawQuery: "kill", mode: .keyword(providerID: "killProcess", keyword: "kill", argument: "")))
        #expect(all.map(\.canonicalKey) == ["process:303", "process:202", "process:101", "process:304"])
        #expect(all[0].badge?.tint == .amber)
        #expect(all[1].badge?.tint == .red)
        #expect(service.listCalls == 1)

        // Subsequent keystroke reuses snapshot cache.
        let byArg = await provider.search(SearchContext(rawQuery: "kill vite", mode: .keyword(providerID: "killProcess", keyword: "kill", argument: "vite")))
        #expect(byArg.map(\.canonicalKey) == ["process:303"])
        #expect(service.listCalls == 1)

        let byPID = await provider.search(SearchContext(rawQuery: "kill 202", mode: .keyword(providerID: "killProcess", keyword: "kill", argument: "202")))
        #expect(byPID.map(\.canonicalKey) == ["process:202"])
    }

    @Test func portQueryFiltersListeningProcessesAndShowsPortBadge() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let node = RunningProcess(pid: 888, name: "node", executablePath: "/opt/homebrew/bin/node", commandLine: "node server.js", memoryBytes: 128 * 1024 * 1024)
        let other = RunningProcess(pid: 999, name: "python3", executablePath: "/usr/bin/python3", memoryBytes: 64 * 1024 * 1024)
        let service = MockProcessService(processes: [node, other], portPIDs: [3000: [888]])
        let provider = KillProcessProvider(settings: settings, service: service)

        let hits = await provider.search(SearchContext(rawQuery: "kill :3000", mode: .keyword(providerID: "killProcess", keyword: "kill", argument: ":3000")))
        #expect(hits.count == 1)
        #expect(hits[0].title == "node")
        #expect(hits[0].badge?.text == ":3000 · 128 MB")

        let empty = await provider.search(SearchContext(rawQuery: "kill :9999", mode: .keyword(providerID: "killProcess", keyword: "kill", argument: ":9999")))
        #expect(empty.count == 1)
        #expect(empty[0].canonicalKey == "process:hint")
    }

    @Test func actionsTerminateForceKillKillAllCopyAndInvalidateCache() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let p1 = RunningProcess(pid: 401, name: "node", executablePath: "/opt/homebrew/bin/node", commandLine: "node a.js", memoryBytes: 100 * 1024 * 1024)
        let p2 = RunningProcess(pid: 402, name: "node", executablePath: "/opt/homebrew/bin/node", commandLine: "node b.js", memoryBytes: 90 * 1024 * 1024)
        let service = MockProcessService(processes: [p1, p2])
        let clipboard = MockClipboard()
        let feedback = MockFeedback()
        var revealed: [URL] = []
        var refreshed = 0

        let provider = KillProcessProvider(
            settings: settings,
            service: service,
            clipboard: clipboard,
            feedback: feedback,
            revealInFinder: { revealed.append($0) }
        )
        provider.onProcessesChanged = { refreshed += 1 }

        let items = await provider.search(SearchContext(rawQuery: "kill node", mode: .keyword(providerID: "killProcess", keyword: "kill", argument: "node")))
        #expect(items.count == 2)
        let first = items[0]
        #expect(first.actions.map(\.id) == [
            "process.terminate",
            "process.forceKill",
            "process.killAll",
            "process.forceKillAll",
            "process.copyPID",
            "process.copyCommand",
            "process.reveal"
        ])

        // Copy PID and command
        try await first.actions[4].run()
        #expect(clipboard.written.last == "401")
        try await first.actions[5].run()
        #expect(clipboard.written.last == "node a.js")
        try await first.actions[6].run()
        #expect(revealed == [URL(fileURLWithPath: "/opt/homebrew/bin/node")])

        // Primary action sends SIGTERM, invalidates cache, and refreshes
        try await first.primaryAction?.run()
        #expect(service.terminated.count == 1)
        #expect(service.terminated[0].pid == 401)
        #expect(service.terminated[0].signal == .terminate)
        #expect(refreshed == 1)

        // Secondary action sends SIGKILL on remaining item
        try await items[1].secondaryAction?.run()
        #expect(service.terminated.count == 2)
        #expect(service.terminated[1].pid == 402)
        #expect(service.terminated[1].signal == .forceKill)

        // Error feedback on permission denied
        service.setTerminateError(ProcessControlError.permissionDenied(pid: 401))
        try await first.primaryAction?.run()
        #expect(feedback.messages.last?.contains("没有权限") == true)
    }

    @Test func unavailableKeywordsExcludeOccupiedPrefixes() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = KillProcessProvider(
            settings: settings,
            service: MockProcessService(),
            unavailableKeywords: { ["KILL"] }
        )
        #expect(provider.keywords == ["kp", "进程"])
    }
}
