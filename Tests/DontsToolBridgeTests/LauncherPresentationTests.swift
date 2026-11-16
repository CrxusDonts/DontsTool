import AppKit
import DontsToolCore
import SwiftUI
import Testing

@Suite("Native launcher presentation", .serialized)
@MainActor
struct LauncherPresentationTests {
    @Test func everyPasteCommandAttachesContentWithoutInsertingIntoQuery() {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let original = " \n{\"private\":true} \n"
        pasteboard.setString(original, forType: .string)
        let editor = LauncherFieldEditor()
        editor.isFieldEditor = true
        editor.pasteboardForPaste = { pasteboard }
        var attached: [String] = []
        editor.onPasteContent = { attached.append($0); return true }
        editor.paste(nil)
        editor.pasteAsPlainText(nil)
        editor.pasteAsRichText(nil)
        #expect(attached == [original, original, original])
        #expect(editor.string.isEmpty)
    }

    @Test func rendersBothAppearancesAttachedContentAndActions() async throws {
        _ = NSApplication.shared
        let defaultsName = "dontstool.launcher.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults)
        let content = ContentActionProvider(settings: settings, toolOpener: PresentationTools(),
            urlOpener: PresentationURLs(), feedback: PresentationFeedback())
        let provider = PresentationProvider()
        let coordinator = SearchCoordinator(registry: ToolRegistry(providers: [provider]), slowDelay: .zero)
        let model = LauncherPanelModel(coordinator: coordinator, hotKeyDisplay: "⌥⌥", contentProvider: content)
        model.submit("")
        try await until { model.items.count == 6 }
        let field = SearchField()
        try capture(model, field: field, settings: settings, name: "launcher-dark", appearance: .darkAqua)
        try capture(model, field: field, settings: settings, name: "launcher-light", appearance: .aqua)
        model.openActionPanel()
        try capture(model, field: field, settings: settings, name: "launcher-actions", appearance: .darkAqua)
        #expect(model.attachContent("{\"name\": \"DontsTool\", \"ready\": true}"))
        field.setContentMode(true)
        try capture(model, field: field, settings: settings, name: "launcher-content", appearance: .darkAqua)
        model.clearContent()
        field.setContentMode(false)
        field.stringValue = "file README"
        model.updateQueryText("file README")
        model.updateQueryRoute(KeywordRoute(providerID: ProviderID.file.rawValue, keyword: "file"))
        model.submit("file-preview")
        try await until { model.items.first?.canonicalKey == "file-preview" }
        try capture(model, field: field, settings: settings, name: "launcher-file-dark", appearance: .darkAqua)
        try capture(model, field: field, settings: settings, name: "launcher-file-light", appearance: .aqua)
    }

    @Test func reopeningCannotRunAnOlderDismissalCompletion() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let driver = PanelTransitionDriver()
        defer { driver.cancel(); panel.close() }
        let origin = NSPoint(x: 180, y: 180)
        var oldDismissalCompleted = false
        driver.show(panel: panel, at: origin)
        driver.hide(panel: panel) { oldDismissalCompleted = true }
        let completedBeforeReopening = oldDismissalCompleted
        #expect(completedBeforeReopening == Motion.reduceMotion)
        driver.show(panel: panel, at: origin)
        try await until { panel.alphaValue == 1 && panel.frame.origin == origin }
        #expect(panel.isVisible)
        #expect(oldDismissalCompleted == completedBeforeReopening)
    }

    @Test func rendersWebsiteEnvironmentCandidatesInBothAppearances() async throws {
        _ = NSApplication.shared
        let defaultsName = "dontstool.website.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = WebsiteShortcutStore(defaults: defaults)
        try store.importJSON("""
        {"version":2,"groups":[{"keyword":"ops","name":"公司系统","items":[
          {"key":"orders","name":"订单后台","aliases":["订单"],"environments":[
            {"key":"test","name":"测试","url":"https://orders.test.company.example"},
            {"key":"prod","name":"生产","url":"https://orders.company.example"}
          ]}
        ]}]}
        """)
        let provider = WebsiteShortcutProvider(store: store, opener: PresentationURLs(),
            feedback: PresentationFeedback(), prefill: PresentationPrefill())
        let model = LauncherPanelModel(coordinator: SearchCoordinator(registry: ToolRegistry(providers: [provider]), slowDelay: .zero), hotKeyDisplay: "⌥⌥")
        let settings = SettingsStore(defaults: defaults)
        let field = SearchField()
        field.stringValue = "ops 订单"
        model.updateQueryText(field.stringValue)
        model.submit(field.stringValue)
        try await until { model.items.count == 2 }
        #expect(Set(model.items.compactMap { $0.badge?.text }) == ["TEST", "PROD"])
        #expect(Set(model.items.map(\.id)).count == 2)
        try capture(model, field: field, settings: settings, name: "website-environments-dark", appearance: .darkAqua)
        try capture(model, field: field, settings: settings, name: "website-environments-light", appearance: .aqua)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let view = NSHostingView(rootView: ScrollView { WebsiteShortcutsSettingsView(store: store).padding(24) }.background(Theme.panelSolid))
            window.contentView = view
            window.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: 620, height: 520)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("build/launcher-previews")
            try png.write(to: folder.appendingPathComponent("website-settings-\(name).png"))
        }
    }

    @Test func transitionUsesTheWindowsDisplayAndReleasesItsFrameSource() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let driver = PanelTransitionDriver()
        defer { driver.cancel(); panel.close() }
        panel.animationBehavior = .utilityWindow
        driver.show(panel: panel, at: NSPoint(x: 180, y: 180))
        #expect(panel.animationBehavior == .none)
        if !Motion.reduceMotion {
            #expect(driver.isDisplayLinked)
        }
        try await until { panel.alphaValue == 1 }
        #expect(!driver.isDisplayLinked)
        var completed = false
        driver.hide(panel: panel) { completed = true; panel.orderOut(nil) }
        try await until { completed }
        #expect(!driver.isDisplayLinked)
        #expect(!panel.isVisible)
    }

    @Test func releasingADriverInvalidatesItsSourceWithoutWaitingForAnotherFrame() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var driver: PanelTransitionDriver? = PanelTransitionDriver()
        driver?.show(panel: panel, at: NSPoint(x: 180, y: 180))
        weak var source = driver?.displayLink
        panel.orderOut(nil)
        driver = nil
        #expect(source == nil)
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw PresentationError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func capture(_ model: LauncherPanelModel, field: SearchField, settings: SettingsStore,
                         name: String, appearance: NSAppearance.Name) throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/launcher-previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.panelSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: LauncherPanelView(model: model, searchField: field, settings: settings,
            onOpenSettings: {}, onExecute: { _, _ in }, onExecuteAction: { _ in }, onClearQuery: {},
            onClearContent: {}, onShowActions: {}, onCopyFilePath: { _ in }))
        window.contentView = view
        window.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(origin: .zero, size: Metrics.panelSize)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent(name + ".png"))
        // A field editor cannot belong to multiple hosting hierarchies at once.
        window.contentView = nil
    }
}

private enum PresentationError: Error { case timeout }
@MainActor private final class PresentationTools: ToolOpening { func openTool(_ request: ToolOpenRequest) {} }
@MainActor private final class PresentationURLs: URLOpening { func open(_ url: URL) throws {} }
@MainActor private final class PresentationFeedback: FeedbackProviding { func show(_ message: String) {} }
@MainActor private final class PresentationPrefill: QueryPrefilling { func prefill(_ query: String) {} }

@MainActor private final class PresentationProvider: ToolProvider {
    let id = "preview"
    let displayName = "Preview"
    let keywords: [String] = []
    let priority = 1
    var isEnabled = true
    func search(_ context: SearchContext) async -> [SearchItem] {
        if context.query == "file-preview" {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("README.md")
            return [SearchItem(providerID: id, group: .file, title: "README.md",
                subtitle: PathDisplay.parentDirectory(of: url), icon: .file(path: url.path),
                score: 1, canonicalKey: "file-preview", actions: [
                    ItemAction(id: "file.open", title: "打开", symbol: "arrow.up.forward.app") {},
                    ItemAction(id: "file.reveal", title: "在访达中显示", symbol: "folder", fileAction: .reveal) {},
                    ItemAction(id: "file.copy", title: "复制路径", symbol: "doc.on.doc", fileAction: .copyPath) {}
                ])]
        }
        let apps: [(String, String)] = [("Visual Studio Code", "/Applications/Visual Studio Code.app"),
            ("终端", "/System/Applications/Utilities/Terminal.app"), ("微信", "/Applications/WeChat.app"),
            ("Figma", "/Applications/Figma.app")]
        return apps.map { title, path in
            SearchItem(providerID: id, group: .app, title: title, subtitle: PathDisplay.parentDirectory(of: URL(fileURLWithPath: path)),
                icon: .application(path: path), score: 1, canonicalKey: path, actions: [
                    ItemAction(id: "open", title: "打开", symbol: "arrow.up.forward.app") {},
                    ItemAction(id: "reveal", title: "在访达中显示", symbol: "folder") {},
                    ItemAction(id: "copy", title: "复制路径", symbol: "doc.on.doc") {}
                ])
        } + [
            SearchItem(providerID: id, group: .tool, title: "JSON 工作台", subtitle: "格式化、校验与结构对比", icon: .glyph(text: "{}", tint: .teal), score: 1, canonicalKey: "json", actions: [ItemAction(id: "json", title: "打开") {}], keyword: "json"),
            SearchItem(providerID: id, group: .tool, title: "Base64", subtitle: "文本编码与解码", icon: .glyph(text: "64", tint: .amber), score: 1, canonicalKey: "base64", actions: [ItemAction(id: "b64", title: "打开") {}], keyword: "b64")
        ]
    }
}
