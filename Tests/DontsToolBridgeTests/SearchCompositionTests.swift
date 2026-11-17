import AppKit
@testable import DontsToolCore
import Testing

@Suite("启动器输入法组合态", .serialized)
@MainActor
struct SearchCompositionTests {
    @Test(arguments: [false, true])
    func compositionCancelsOldFileSearchAndOnlySearchesCommittedChinese(useInsertText: Bool) async throws {
        let fixture = try CompositionFixture()
        defer { fixture.close() }
        fixture.controller.prefill("file old")
        let editor = try #require(fixture.field.currentEditor() as? NSTextView)
        editor.setMarkedText("baogao", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: 5, length: 3))
        #expect(editor.hasMarkedText())
        await fixture.coordinator.waitForPendingSearch()
        #expect(fixture.provider.queries.isEmpty)
        // Index/settings refreshes must not revive the pre-composition query.
        fixture.controller.refreshSearch()
        await fixture.coordinator.waitForPendingSearch()
        #expect(fixture.provider.queries.isEmpty)

        var actions = 0
        fixture.field.onConfirm = { actions += 1 }
        fixture.field.onMoveDown = { actions += 1 }
        fixture.field.onCancel = { actions += 1 }
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(!fixture.field.control(fixture.field, textView: editor, doCommandBy: selector))
        }
        #expect(actions == 0)

        editor.setMarkedText("报告", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.markedRange())
        if useInsertText {
            editor.insertText("报告", replacementRange: editor.markedRange())
        } else {
            editor.unmarkText()
        }
        #expect(!editor.hasMarkedText())
        await fixture.coordinator.waitForPendingSearch()
        #expect(fixture.field.stringValue == "file 报告")
        #expect(fixture.provider.queries == ["报告"])
    }
}

@MainActor
private struct CompositionFixture {
    let controller: LauncherPanelController
    let coordinator: SearchCoordinator
    let field: SearchField
    let panel: NSWindow
    let provider = CompositionFiles()
    private let defaultsName = "dontstool.composition.\(UUID())"

    init() throws {
        _ = NSApplication.shared
        let settings = SettingsStore(defaults: UserDefaults(suiteName: defaultsName)!)
        let registry = ToolRegistry(providers: [provider])
        coordinator = SearchCoordinator(registry: registry)
        let windowController = LauncherPanelController(registry: registry, coordinator: coordinator,
            toast: CompositionFeedback(), hotKeyDisplay: "⌥Space", settings: settings,
            contentProvider: ContentActionProvider(settings: settings, toolOpener: CompositionTools(),
                urlOpener: CompositionURLs(), feedback: CompositionFeedback()))
        controller = windowController
        windowController.show()
        panel = try #require(NSApp.windows.first { $0.delegate === windowController })
        func find(_ view: NSView) -> SearchField? {
            (view as? SearchField) ?? view.subviews.lazy.compactMap(find).first
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        field = try #require(panel.contentView.flatMap(find))
    }

    func close() {
        controller.hide(restorePreviousApp: false)
        panel.orderOut(nil)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}

@MainActor private final class CompositionFiles: ToolProvider {
    let id = "file"
    let displayName = "文件"
    let keywords = ["file"]
    let priority = 50
    let phase = SearchPhase.slow
    var isEnabled = true
    var statusNotice: String? { nil }
    var queries: [String] = []
    func search(_ context: SearchContext) async -> [SearchItem] {
        queries.append(context.query)
        return []
    }
}
@MainActor private final class CompositionFeedback: FeedbackProviding { func show(_ message: String) {} }
@MainActor private final class CompositionTools: ToolOpening { func openTool(_ request: ToolOpenRequest) {} }
@MainActor private final class CompositionURLs: URLOpening { func open(_ url: URL) throws {} }
