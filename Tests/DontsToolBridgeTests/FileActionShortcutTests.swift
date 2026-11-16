import AppKit
import Testing
@testable import DontsToolCore

@Suite("File action shortcuts", .serialized)
@MainActor
struct FileActionShortcutTests {
    @Test func ordinaryCopyAndOtherModifierCombinationsDoNotInvokePathCopy() throws {
        _ = NSApplication.shared
        let field = SearchField()
        var pathCopies = 0
        field.onCopyFilePath = { pathCopies += 1; return true }
        for flags: NSEvent.ModifierFlags in [.command, [.command, .shift, .option], [.command, .shift, .control]] {
            _ = field.performKeyEquivalent(with: try key("c", flags: flags))
        }
        #expect(pathCopies == 0)
        #expect(field.performKeyEquivalent(with: try key("C", flags: [.command, .shift])))
        #expect(pathCopies == 1)
    }

    @Test func commandShiftCCopiesSelectedFilePathWithoutOpeningFile() async throws {
        let fixture = try FileShortcutFixture()
        defer { fixture.close() }
        fixture.controller.prefill("/tmp/report.pdf")
        await fixture.coordinator.waitForPendingSearch()
        #expect(fixture.field.performKeyEquivalent(with: try key("C", flags: [.command, .shift])))
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.clipboard.written == ["/tmp/report.pdf"])
        #expect(fixture.launcher.opened.isEmpty)
        #expect(fixture.launcher.revealed.isEmpty)
        #expect(fixture.feedback.messages == ["已复制 report.pdf 的路径"])
        #expect(fixture.field.stringValue == "/tmp/report.pdf")
    }

    @Test func nonFileSelectionAndMarkedTextDoNotCopyAFilePath() async throws {
        let fixture = try FileShortcutFixture()
        defer { fixture.close() }
        fixture.controller.prefill("https://example.com")
        await fixture.coordinator.waitForPendingSearch()
        _ = fixture.field.performKeyEquivalent(with: try key("C", flags: [.command, .shift]))
        fixture.controller.prefill("/tmp/report.pdf")
        await fixture.coordinator.waitForPendingSearch()
        let editor = try #require(fixture.field.currentEditor() as? NSTextView)
        editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        _ = fixture.field.performKeyEquivalent(with: try key("C", flags: [.command, .shift]))
        editor.unmarkText()
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.clipboard.written.isEmpty)
        #expect(fixture.launcher.opened.isEmpty)
    }

    @Test func actionMenuDoesNotRunTheUnderlyingFileCopyShortcut() async throws {
        let fixture = try FileShortcutFixture()
        defer { fixture.close() }
        fixture.controller.prefill("/tmp/report.pdf")
        await fixture.coordinator.waitForPendingSearch()
        let menuKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        #expect(fixture.field.performKeyEquivalent(with: menuKey))
        _ = fixture.field.performKeyEquivalent(with: try key("C", flags: [.command, .shift]))
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.clipboard.written.isEmpty)
        #expect(fixture.launcher.opened.isEmpty)
    }

    private func key(_ text: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 8))
    }
}

@MainActor private struct FileShortcutFixture {
    let controller: LauncherPanelController
    let coordinator: SearchCoordinator
    let panel: NSWindow
    let field: SearchField
    let clipboard = ShortcutClipboard()
    let launcher = ShortcutLauncher()
    let feedback = ShortcutFeedback()
    private let name = "dontstool.file.shortcut.\(UUID().uuidString)"

    init() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: name)!
        let settings = SettingsStore(defaults: defaults)
        let provider = QuickOpenProvider(settings: settings, usage: UsageStore(defaults: defaults),
            launcher: launcher, opener: ShortcutURLs(), clipboard: clipboard, feedback: feedback,
            fileExists: { $0 == "/tmp/report.pdf" })
        let registry = ToolRegistry(providers: [provider])
        coordinator = SearchCoordinator(registry: registry, slowDelay: .zero)
        let controller = LauncherPanelController(registry: registry, coordinator: coordinator,
            toast: feedback, hotKeyDisplay: "⌥⌥", settings: settings,
            contentProvider: ContentActionProvider(settings: settings, toolOpener: ShortcutTools(),
                urlOpener: ShortcutURLs(), feedback: feedback))
        self.controller = controller
        controller.show()
        let panel = try #require(NSApp.windows.first { $0.delegate === controller })
        self.panel = panel
        func find(_ view: NSView) -> SearchField? {
            if let field = view as? SearchField { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        field = try #require(panel.contentView.flatMap(find))
    }

    func close() {
        controller.hide(restorePreviousApp: false)
        panel.orderOut(nil)
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

@MainActor private final class ShortcutClipboard: ClipboardProviding {
    var written: [String] = []
    func readString() -> String? { nil }
    func writeString(_ string: String) { written.append(string) }
}
@MainActor private final class ShortcutFeedback: FeedbackProviding {
    var messages: [String] = []
    func show(_ message: String) { messages.append(message) }
}
@MainActor private final class ShortcutLauncher: AppLaunching {
    var opened: [URL] = []
    var revealed: [URL] = []
    func openApplication(at url: URL) async throws {}
    func openFile(at url: URL) throws { opened.append(url) }
    func revealInFinder(_ url: URL) { revealed.append(url) }
    func quitApplication(at url: URL) -> Bool { false }
}
@MainActor private final class ShortcutURLs: URLOpening { func open(_ url: URL) throws {} }
@MainActor private final class ShortcutTools: ToolOpening { func openTool(_ request: ToolOpenRequest) {} }
