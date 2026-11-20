import Foundation
import os
import Testing
@testable import DontsToolCore

@Suite("TerminalFinder")
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
            var lastRequestedTerminalBundleID: String?
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
            state.withLock {
                $0.lastRequestedTerminalBundleID = preferredBundleID
                return $0.terminalDirectory
            }
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

    // MARK: - Contextual Ranking & Terminal Preference

    @Test func prioritizesFinderToTerminalWhenInvokedFromFinder() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = MockTerminalService()
        service.state.withLock { $0.running = [TerminalAppCatalog.warpBundleID] }
        let usage = UsageStore(defaults: defaults)
        let clipboard = SpyClipboard()
        let provider = TerminalFinderProvider(
            settings: settings,
            service: service,
            clipboard: clipboard,
            feedback: SpyFeedback(),
            usage: usage
        )

        let items = await provider.search(SearchContext(
            rawQuery: "tf ",
            mode: .keyword(providerID: provider.id, keyword: "tf", argument: ""),
            frontmostBundleID: TerminalAppCatalog.finderBundleID
        ))

        let first = try #require(items.first)
        #expect(first.title == "在 Warp 中打开当前访达目录")
        #expect(first.badge?.text == "当前访达")

        // Execute primary action -> opens Finder directory in Warp and records usage
        try await first.primaryAction?.run()
        let opened = service.state.withLock(\.openedInTerminal)
        #expect(opened.count == 1)
        #expect(opened[0].0.path == "/Users/test/Projects/Demo")
        #expect(opened[0].1 == TerminalAppCatalog.warpBundleID)
        #expect(usage.record(for: TerminalFinderProvider.entryCanonicalKey)?.count == 1)

        // Alternative terminal action in action palette (Ghostty)
        let ghosttyAction = try #require(first.actions.first { $0.id == "tf.finderToTerminal.\(TerminalAppCatalog.ghosttyBundleID)" })
        try await ghosttyAction.run()
        #expect(service.state.withLock(\.openedInTerminal).last?.1 == TerminalAppCatalog.ghosttyBundleID)
    }

    @Test func prioritizesTerminalToFinderWhenInvokedFromGhostty() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = MockTerminalService()
        let usage = UsageStore(defaults: defaults)
        let provider = TerminalFinderProvider(
            settings: settings,
            service: service,
            clipboard: SpyClipboard(),
            feedback: SpyFeedback(),
            usage: usage
        )

        let items = await provider.search(SearchContext(
            rawQuery: "tf ",
            mode: .keyword(providerID: provider.id, keyword: "tf", argument: ""),
            frontmostBundleID: TerminalAppCatalog.ghosttyBundleID
        ))

        let first = try #require(items.first)
        #expect(first.title == "在访达中打开Ghostty当前目录")
        #expect(first.badge?.text == "当前终端")

        try await first.primaryAction?.run()
        #expect(service.state.withLock(\.lastRequestedTerminalBundleID) == TerminalAppCatalog.ghosttyBundleID)
        #expect(service.state.withLock(\.openedInFinder).map(\.path) == ["/Users/test/Workspace/App"])
        #expect(usage.record(for: TerminalFinderProvider.entryCanonicalKey)?.count == 1)
    }

    @Test func respectsPreferredTerminalSettingAndSupportsExplicitTerminalFilteringAndPaths() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.setPreferredTerminalBundleID(TerminalAppCatalog.iterm2BundleID)

        let service = MockTerminalService()
        let provider = TerminalFinderProvider(settings: settings, service: service)

        #expect(provider.preferredTerminal()?.bundleID == TerminalAppCatalog.iterm2BundleID)

        // Explicit terminal alias `otty` resolves Ghostty
        let ottyItems = await provider.search(SearchContext(
            rawQuery: "tf otty",
            mode: .keyword(providerID: provider.id, keyword: "tf", argument: "otty")
        ))
        #expect(ottyItems.first?.title == "在 Ghostty 中打开当前访达目录")

        // Direct path argument opens that directory in preferred terminal (iTerm2)
        let pathItems = await provider.search(SearchContext(
            rawQuery: "tf /tmp",
            mode: .keyword(providerID: provider.id, keyword: "tf", argument: "/tmp")
        ))
        let pathItem = try #require(pathItems.first)
        #expect(pathItem.title == "在 iTerm2 中打开 tmp")
        try await pathItem.primaryAction?.run()
        #expect(service.state.withLock(\.openedInTerminal).last?.0.path == "/tmp")
        #expect(service.state.withLock(\.openedInTerminal).last?.1 == TerminalAppCatalog.iterm2BundleID)
    }

    @Test func fileAndQuickOpenProvidersExposeOpenInTerminalAction() async throws {
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
