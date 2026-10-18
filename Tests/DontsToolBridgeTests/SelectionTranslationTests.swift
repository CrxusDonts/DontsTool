import AppKit
import DontsToolCore
import SwiftUI
import Testing

@Suite("划词翻译原生卡片", .serialized)
@MainActor
struct SelectionTranslationTests {
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
