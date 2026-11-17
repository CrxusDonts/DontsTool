import AppKit
import DontsToolCore
import SwiftUI
import Testing

@Suite("划词翻译原生卡片", .serialized)
@MainActor
struct SelectionTranslationTests {
    @Test func changingHoldDelayUpdatesTheActiveControllerWithoutRestart() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let controller = SelectionTranslationController(settings: settings, translator: ImmediateSelectionTranslator())
        defer { controller.shutdown() }
        settings.setSelectionHoldDelay(.milliseconds300)
        try await until { controller.holdDelayLabel == "300 ms" }
        #expect(controller.holdDelayLabel == "300 ms")
    }

    @Test func applicationChangeDismissesOnlyVisibleUnpinnedCard() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let controller = SelectionTranslationController(settings: settings, translator: ImmediateSelectionTranslator())
        defer { controller.shutdown() }
        controller.show(text: "event propagation", at: CGPoint(x: 300, y: 200))
        controller.pinned = true
        controller.dismissForApplicationChange()
        #expect(translationPanel(for: controller)?.isVisible == true)
        controller.pinned = false
        controller.dismissForApplicationChange()
        #expect(translationPanel(for: controller)?.isVisible != true)
    }

    @Test func reusingCardCannotPublishAnEarlierTranslation() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let translator = DelayedSelectionTranslator()
        let controller = SelectionTranslationController(settings: settings, translator: translator)
        defer { controller.shutdown() }
        controller.show(text: "first selection", at: CGPoint(x: 300, y: 200))
        try await until { translator.requests.count == 1 }
        controller.show(text: "second selection", at: CGPoint(x: 320, y: 200))
        try await until { translator.requests.count == 2 }
        translator.requests[1].resume(returning: "第二段译文")
        try await until { controller.session.output == "第二段译文" }
        translator.requests[0].resume(returning: "过期译文")
        try await until { translator.completed.contains("first selection") }
        #expect(controller.session.input == "second selection")
        #expect(controller.session.output == "第二段译文")
        #expect(controller.session.canCopy)
    }

    @Test func dismissCancelsPendingTranslationWithoutPublishingLateResult() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let translator = DelayedSelectionTranslator()
        let controller = SelectionTranslationController(settings: settings, translator: translator)
        defer { controller.shutdown() }
        controller.show(text: "pending", at: CGPoint(x: 300, y: 200))
        try await until { translator.requests.count == 1 }
        controller.dismiss()
        #expect(!controller.session.isRunning)
        #expect(!controller.session.canCopy)
        translator.requests[0].resume(returning: "should not appear")
        try await until { translator.completed.contains("pending") }
        #expect(!controller.session.isFresh)
    }

    @Test func nativeCardRendersConfiguredAndUnconfiguredStates() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let service = ImmediateSelectionTranslator()
        let controller = SelectionTranslationController(settings: settings, translator: service)
        defer { controller.shutdown() }
        controller.session.input = "event propagation"
        controller.session.target = "zh-Hans"
        await controller.session.perform()
        #expect(controller.session.output == "事件传播")
        try capture(controller, name: "native-dark", appearance: .darkAqua)
        try capture(controller, name: "native-light", appearance: .aqua)
        service.result = """
        run

        动词 v.
        1. 跑；奔跑。
        2. （程序、机器）运行；运转。
        3. 管理；经营（run a company）。
        例：The engine is running. 发动机正在运转。

        名词 n.
        1. 跑步；奔跑。
        2. 一段连续时间；一连串事件。
        3. 行程；路线；班次。
        例：We went for a run. 我们去跑步了。
        """
        controller.session.input = "run"
        await controller.session.perform()
        #expect(controller.session.canCopy)
        try capture(controller, name: "native-dictionary-dark", appearance: .darkAqua)
        try capture(controller, name: "native-dictionary-light", appearance: .aqua)
        controller.session.input = "a new selection"
        service.isConfigured = false
        await controller.session.perform()
        #expect(!controller.session.canCopy)
        #expect(controller.session.errorMessage != nil)
        try capture(controller, name: "native-unconfigured", appearance: .darkAqua)
    }

    @Test func readingAndSelectionFailureStayInvisibleWithoutSendingTranslation() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let translator = DelayedSelectionTranslator()
        let controller = SelectionTranslationController(settings: settings, translator: translator)
        defer { controller.shutdown() }
        controller.showReading(at: CGPoint(x: 300, y: 200))
        #expect(controller.selectionReadInProgress)
        #expect(translationPanel(for: controller)?.isVisible != true)
        controller.showSelectionFailure("应用未提供选中文字", at: CGPoint(x: 300, y: 200))
        #expect(translationPanel(for: controller)?.isVisible != true)
        #expect(controller.selectionFailure == "应用未提供选中文字")
        #expect(controller.session.input.isEmpty)
        #expect(!controller.session.isRunning)
        #expect(!controller.session.canCopy)
        #expect(translator.requests.isEmpty)
        #expect(!controller.selectionReadInProgress)
        #expect(controller.lastGestureDiagnostic == "应用未提供选中文字")
    }

    @Test(arguments: ["", "  \n\t", "\u{00A0}\u{2003}"])
    func whitespaceCannotOpenCardOrStartTranslation(_ text: String) async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let translator = DelayedSelectionTranslator()
        let controller = SelectionTranslationController(settings: settings, translator: translator)
        defer { controller.shutdown() }
        controller.show(text: text, at: CGPoint(x: 300, y: 200))
        for _ in 0..<20 { await Task.yield() }
        #expect(translationPanel(for: controller)?.isVisible != true)
        #expect(!controller.session.isRunning)
        #expect(translator.requests.isEmpty)
        for request in translator.requests { request.resume(returning: "unexpected") }
    }

    @Test func failedReadDoesNotReplaceAnExistingPinnedTranslation() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let controller = SelectionTranslationController(settings: settings, translator: ImmediateSelectionTranslator())
        defer { controller.shutdown() }
        controller.show(text: "event propagation", at: CGPoint(x: 300, y: 200))
        try await until { controller.session.isFresh }
        controller.pinned = true
        controller.showReading(at: CGPoint(x: 320, y: 200))
        controller.showSelectionFailure("未选中文字", at: CGPoint(x: 320, y: 200))
        #expect(translationPanel(for: controller)?.isVisible == true)
        #expect(controller.session.input == "event propagation")
        #expect(controller.session.output == "事件传播")
        #expect(controller.session.canCopy)
    }

    @Test func applicationChangeCancelsInvisibleReadingEvenWhenAnOlderCardIsPinned() throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let controller = SelectionTranslationController(settings: settings, translator: ImmediateSelectionTranslator())
        defer { controller.shutdown() }
        controller.pinned = true
        controller.showReading(at: CGPoint(x: 300, y: 200))
        controller.dismissForApplicationChange()
        #expect(!controller.selectionReadInProgress)
        #expect(translationPanel(for: controller)?.isVisible != true)
    }

    @Test func readingCardCannotSendAnEarlierSourceToTranslator() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let translator = DelayedSelectionTranslator()
        let controller = SelectionTranslationController(settings: settings, translator: translator)
        defer { controller.shutdown() }
        controller.session.input = "old selection"
        controller.showReading(at: CGPoint(x: 300, y: 200))
        #expect(controller.selectionReadInProgress)
        #expect(controller.session.input.isEmpty)
        #expect(translator.requests.isEmpty)
    }

    @Test func closingOrEditingReadCardCannotReopenItOrSendLateSelection() async throws {
        for editInsteadOfClose in [false, true] {
            let (settings, defaults, name) = makeSettings()
            defer { defaults.removePersistentDomain(forName: name) }
            _ = NSApplication.shared
            let translator = DelayedSelectionTranslator()
            var readContinuation: CheckedContinuation<Void, Never>?
            var readReturned = false
            var edited = false
            var now: TimeInterval = 0
            let monitor = RightPressMonitor(environment: .init(now: { now }, buttonIsDown: { true },
                frontmostPID: { 42 }, foregroundWindow: { _, _ in 7 },
                readSelection: { _, _ in
                    await withCheckedContinuation { readContinuation = $0 }
                    readReturned = true
                    return SelectionReading(text: "late closed selection", diagnostic: "已读取选区")
                }, waitForHold: { _ in now = 2 }, waitForReadTimeout: { try await Task.sleep(for: .seconds(3)) },
                restore: { _, _, _, _, _ in Issue.record("A committed translation hold must not replay native events"); return false }))
            let controller = SelectionTranslationController(settings: settings, translator: translator, monitor: monitor)
            defer { controller.shutdown() }
            controller.onEditSource = { _ in edited = true }
            let down = try #require(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                mouseCursorPosition: CGPoint(x: 300, y: 200), mouseButton: .right))
            down.timestamp = 0
            #expect(!monitor.handle(.rightMouseDown, event: down, proxy: nil))
            try await until { readContinuation != nil }
            #expect(controller.selectionReadInProgress)
            if editInsteadOfClose { controller.editSource() } else { controller.dismiss() }
            readContinuation?.resume()
            try await until { readReturned }
            for _ in 0..<20 { await Task.yield() }
            #expect(translator.requests.isEmpty)
            #expect(!controller.session.isRunning)
            #expect(!controller.selectionReadInProgress)
            #expect(edited == editInsteadOfClose)
            let up = try #require(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                mouseCursorPosition: down.location, mouseButton: .right))
            #expect(!monitor.handle(.rightMouseUp, event: up, proxy: nil))
            for request in translator.requests { request.resume(returning: "unexpected translation") }
        }
    }

    private func makeSettings() -> (SettingsStore, UserDefaults, String) {
        let name = "dontstool.selection.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (SettingsStore(defaults: defaults, systemLanguageCode: "zh"), defaults, name)
    }

    private func translationPanel(for controller: SelectionTranslationController) -> NSWindow? {
        NSApp.windows.first { window in
            (window.contentView as? NSHostingView<SelectionTranslationView>)?.rootView.controller === controller
        }
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SelectionTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func capture(_ controller: SelectionTranslationController, name: String, appearance: NSAppearance.Name) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("build/selection-previews").path
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 330),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: SelectionTranslationView(controller: controller, session: controller.session))
        window.contentView = view
        window.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 330)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

private enum SelectionTestError: Error { case timeout }

@MainActor
private final class DelayedSelectionTranslator: TranslationServicing {
    let isConfigured = true
    var requests: [CheckedContinuation<String, any Error>] = []
    var completed: [String] = []
    func translate(_ text: String, target: String) async throws -> String {
        let result: String = try await withCheckedThrowingContinuation { requests.append($0) }
        completed.append(text)
        return result
    }
}

@MainActor
private final class ImmediateSelectionTranslator: TranslationServicing {
    var isConfigured = true
    var result = "事件传播"
    func translate(_ text: String, target: String) async throws -> String { result }
}
