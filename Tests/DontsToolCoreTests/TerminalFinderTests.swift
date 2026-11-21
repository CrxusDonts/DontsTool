import Foundation
import os
import Testing
@testable import DontsToolCore

@Suite("TerminalService")
@MainActor
struct TerminalFinderTests {
    private final class MockTerminalService: TerminalFinderControlling, @unchecked Sendable {
        struct State {
            var installed: [TerminalAppDescriptor] = [
                TerminalAppCatalog.descriptor(forBundleID: TerminalAppCatalog.ghosttyBundleID)!.withAppPath("/Applications/Ghostty.app"),
                TerminalAppCatalog.descriptor(forBundleID: TerminalAppCatalog.warpBundleID)!.withAppPath("/Applications/Warp.app"),
                TerminalAppCatalog.descriptor(forBundleID: TerminalAppCatalog.iterm2BundleID)!.withAppPath("/Applications/iTerm.app"),
                TerminalAppCatalog.descriptor(forBundleID: TerminalAppCatalog.appleTerminalBundleID)!.withAppPath("/System/Applications/Utilities/Terminal.app")
            ]
            var running: [String] = []
            var finderDirectory = URL(fileURLWithPath: "/Users/test/Projects/Demo", isDirectory: true)
            var terminalDirectory = URL(fileURLWithPath: "/Users/test/Workspace/App", isDirectory: true)
            var openedInTerminal: [(URL, String)] = []
            var openedInFinder: [URL] = []
        }

        let state = OSAllocatedUnfairLock(initialState: State())

        func installedTerminals() -> [TerminalAppDescriptor] { state.withLock(\.installed) }
        func runningTerminalBundleIDs() -> [String] { state.withLock(\.running) }

        func currentFinderDirectory() async throws -> URL {
            state.withLock(\.finderDirectory)
        }

        func currentTerminalDirectory(preferredBundleID: String?) async throws -> URL {
            state.withLock(\.terminalDirectory)
        }

        func openInTerminal(directory: URL, terminalBundleID: String) async throws {
            state.withLock { $0.openedInTerminal.append((directory, terminalBundleID)) }
        }

        func openInFinder(directory: URL) async throws {
            state.withLock { $0.openedInFinder.append(directory) }
        }
    }

    private final class SpyClipboard: ClipboardProviding, @unchecked Sendable {
        var written: [String] = []
        func writeString(_ text: String) { written.append(text) }
        func readString() -> String? { written.last }
    }

    private final class SpyFeedback: FeedbackProviding {
        var messages: [String] = []
        func show(_ message: String) { messages.append(message) }
    }

    private func makeSettings() -> (SettingsStore, UserDefaults, String) {
        let suite = "dontstool.tests.tf.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults, systemLanguageCode: "zh"), defaults, suite)
    }

    // MARK: - Process Tree & CWD Helpers

    @Test func parsesProcessSnapshotAndPicksForegroundShellForGhosttyOrWarp() {
        let raw = """
          100     1 ??       Ss   /Applications/Ghostty.app/Contents/MacOS/ghostty
          120   100 ??       S    /Applications/Ghostty.app/Contents/MacOS/ghostty-helper
          200   100 ttys001  Ss   /usr/bin/login
          210   200 ttys001  S    -zsh
          220   210 ttys001  S+   /opt/homebrew/bin/nvim
          300   100 ttys002  S+   -zsh
        """
        let rows = SystemTerminalFinderService.parseProcessSnapshot(raw)
        #expect(rows.count == 6)

        let candidates = SystemTerminalFinderService.candidateShellPIDs(underRootPIDs: [100], rows: rows)
        // Non-TTY helper (120) must be excluded; foreground shell (300) and foreground child (220) come before idle processes.
        #expect(!candidates.contains(120))
        #expect(Set(candidates.prefix(2)) == Set([300, 220]))

        let tty1Candidates = SystemTerminalFinderService.candidatePIDs(forTTY: "/dev/ttys001", rows: rows)
        #expect(tty1Candidates.first == 220)
    }

    @Test func readsCurrentProcessWorkingDirectoryViaProcPidInfo() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let cwd = SystemTerminalFinderService.workingDirectory(forPID: pid)
        #expect(cwd?.hasPrefix("/") == true)
    }

    // MARK: - Preferred Terminal Selection & Opening

    @Test func resolvesPreferredTerminalRespectingConfiguredFrontmostRunningAndInstalledOrder() async throws {
        let service = MockTerminalService()
        service.state.withLock { $0.running = [TerminalAppCatalog.warpBundleID] }

        // 1. Explicit configured preference wins over frontmost and running.
        #expect(
            service.preferredTerminal(
                configuredBundleID: TerminalAppCatalog.iterm2BundleID,
                frontmostBundleID: TerminalAppCatalog.ghosttyBundleID
            )?.bundleID == TerminalAppCatalog.iterm2BundleID
        )

        // 2. When configured is empty, frontmost terminal wins over other running terminals.
        #expect(
            service.preferredTerminal(
                configuredBundleID: "",
                frontmostBundleID: TerminalAppCatalog.ghosttyBundleID
            )?.bundleID == TerminalAppCatalog.ghosttyBundleID
        )

        // 3. When neither configured nor frontmost is a terminal, running terminal wins.
        #expect(
            service.preferredTerminal(
                configuredBundleID: "",
                frontmostBundleID: TerminalAppCatalog.finderBundleID
            )?.bundleID == TerminalAppCatalog.warpBundleID
        )

        // 4. openPathInPreferredTerminal forwards to the resolved terminal.
        let targetDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
        try await service.openPathInPreferredTerminal(
            targetDir,
            configuredBundleID: TerminalAppCatalog.iterm2BundleID
        )
        let opened = service.state.withLock(\.openedInTerminal)
        #expect(opened.count == 1)
        #expect(opened[0].0.path == "/tmp")
        #expect(opened[0].1 == TerminalAppCatalog.iterm2BundleID)
    }

    @Test func quickOpenProviderExposesOpenInTerminalAction() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        var openedURLs: [URL] = []
        let quickOpen = QuickOpenProvider(
            settings: settings,
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            opener: MockURLOpener(),
            clipboard: SpyClipboard(),
            feedback: SpyFeedback(),
            openInTerminal: { openedURLs.append($0) },
            fileExists: { $0 == "/Users/test/repo" }
        )
        let items = await quickOpen.search(SearchContext(rawQuery: "/Users/test/repo", mode: .global))
        let terminalAction = try #require(items.first?.actions.first { $0.id == "quickopen.file.openInTerminal" })
        try await terminalAction.run()
        #expect(openedURLs == [URL(fileURLWithPath: "/Users/test/repo")])
    }
}
