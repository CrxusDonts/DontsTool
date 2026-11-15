import AppKit
import DontsToolCore
import SwiftUI
import Testing

@Suite("Native website page presentation", .serialized)
@MainActor
struct WebsitePagePresentationTests {
    @Test func rendersPageAndEnvironmentCommandsAndSettings() async throws {
        _ = NSApplication.shared
        let suite = "dontstool.pages.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WebsiteShortcutStore(defaults: defaults)
        try store.importJSON("""
        {"version":3,"groups":[{"keyword":"ops","name":"公司系统","items":[
          {"key":"avatar","name":"Avatar","environments":[
            {"key":"test","name":"测试","url":"https://avatar.test.company.example"},
            {"key":"prod","name":"生产","url":"https://avatar.company.example"}
          ],"pages":[{"key":"management","name":"管理页","path":"/admin/management","aliases":["管理","managment"]}]}
        ]}]}
        """)
        let opener = PagePreviewURLs()
        let provider = WebsiteShortcutProvider(store: store, opener: opener, feedback: PagePreviewFeedback(), prefill: PagePreviewPrefill())
        let model = LauncherPanelModel(coordinator: SearchCoordinator(registry: ToolRegistry(providers: [provider]), slowDelay: .zero), hotKeyDisplay: "⌥⌥")
        let field = SearchField()
        let settings = SettingsStore(defaults: defaults)
        func query(_ value: String, count: Int) async throws {
            field.stringValue = value
            model.updateQueryText(value)
            model.submit(value)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while model.items.count != count {
                guard ContinuousClock.now < deadline else { throw PagePreviewError.timeout }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await query("ops avatar", count: 4)
        #expect(model.items.first?.title == "Avatar · 首页")
        #expect(Set(model.items.map(\.id)).count == 4)
        try captureLauncher(model, field: field, settings: settings, name: "website-pages-list-dark", appearance: .darkAqua)
        try await query("ops avatar management", count: 2)
        #expect(Set(model.items.compactMap { $0.badge?.text }) == ["TEST", "PROD"])
        #expect(model.items.allSatisfy { $0.title == "Avatar · 管理页" })
        try captureLauncher(model, field: field, settings: settings, name: "website-pages-dark", appearance: .darkAqua)
        try captureLauncher(model, field: field, settings: settings, name: "website-pages-light", appearance: .aqua)
        try await query("ops avatar management prod", count: 1)
        #expect(model.items.first?.subtitle == "https://avatar.company.example/admin/management")
        #expect(opener.opened.isEmpty)
        try captureLauncher(model, field: field, settings: settings, name: "website-page-prod-dark", appearance: .darkAqua)
        try await model.items.first?.primaryAction?.run()
        #expect(opener.opened.map(\.absoluteString) == ["https://avatar.company.example/admin/management"])
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            try capture(ScrollView { WebsiteShortcutsSettingsView(store: store).padding(24) }.background(Theme.panelSolid),
                size: NSSize(width: 620, height: 540), name: "website-pages-settings-\(name)", appearance: appearance)
        }
        let single = WebsiteShortcutConfiguration(version: 3, groups: [.init(keyword: "ops", name: "系统", items: [
            .init(key: "avatar", name: "Avatar", url: "https://avatar.company.example", pages: [
                .init(key: "management", name: "管理页", path: "/admin/management", aliases: ["管理", "managment"])
            ])
        ])])
        try capture(ShortcutFormSheet(draft: .item(group: 0, index: 0, value: single.groups[0].items[0]), configuration: single, save: { _ in }),
            size: NSSize(width: 600, height: 590), name: "website-pages-form-dark", appearance: .darkAqua)
    }

    private func captureLauncher(_ model: LauncherPanelModel, field: SearchField, settings: SettingsStore, name: String, appearance: NSAppearance.Name) throws {
        try capture(LauncherPanelView(model: model, searchField: field, settings: settings,
            onOpenSettings: {}, onExecute: { _, _ in }, onExecuteAction: { _ in }, onClearQuery: {},
            onClearContent: {}, onShowActions: {}), size: Metrics.panelSize, name: name, appearance: appearance)
    }

    private func capture<Content: View>(_ content: Content, size: NSSize, name: String, appearance: NSAppearance.Name) throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/launcher-previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: content)
        window.contentView = view
        window.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        window.contentView = nil
    }
}

private enum PagePreviewError: Error { case timeout }
@MainActor private final class PagePreviewURLs: URLOpening {
    var opened: [URL] = []
    func open(_ url: URL) throws { opened.append(url) }
}
@MainActor private final class PagePreviewFeedback: FeedbackProviding { func show(_ message: String) {} }
@MainActor private final class PagePreviewPrefill: QueryPrefilling { func prefill(_ query: String) {} }
