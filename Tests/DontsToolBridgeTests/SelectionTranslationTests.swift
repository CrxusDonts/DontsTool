import AppKit
import DontsToolCore
import SwiftUI
import Testing

@Suite("划词翻译原生卡片", .serialized)
@MainActor
struct SelectionTranslationTests {
    @Test func applicationChangeDismissesOnlyVisibleUnpinnedCard() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let controller = SelectionTranslationController(settings: settings, translator: ImmediateSelectionTranslator())
        defer { controller.shutdown() }
        controller.showReading(at: CGPoint(x: 300, y: 200))
        controller.pinned = true
        controller.dismissForApplicationChange()
        #expect(controller.selectionReadInProgress)
        controller.pinned = false
        controller.dismissForApplicationChange()
        #expect(!controller.selectionReadInProgress)
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
        controller.session.input = "a new selection"
        service.isConfigured = false
        await controller.session.perform()
        #expect(!controller.session.canCopy)
        #expect(controller.session.errorMessage != nil)
        try capture(controller, name: "native-unconfigured", appearance: .darkAqua)
    }

    @Test func selectionFailureShowsEditableCardWithoutSendingTranslation() async throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = NSApplication.shared
        let translator = DelayedSelectionTranslator()
        let controller = SelectionTranslationController(settings: settings, translator: translator)
        defer { controller.shutdown() }
        controller.showSelectionFailure("应用未提供选中文字", at: CGPoint(x: 300, y: 200))
        #expect(controller.selectionFailure == "应用未提供选中文字")
        #expect(controller.session.input.isEmpty)
        #expect(!controller.session.isRunning)
        #expect(!controller.session.canCopy)
        #expect(translator.requests.isEmpty)
        var edited: String?
        controller.onEditSource = { edited = $0 }
        controller.editSource()
        #expect(edited == "")
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
                }, waitForHold: { now = 2 }, waitForReadTimeout: { try await Task.sleep(for: .seconds(3)) },
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
    func translate(_ text: String, target: String) async throws -> String { "事件传播" }
}
