import AppKit
import DontsToolCore
import SwiftUI
import Testing

@Suite("Search engine settings", .serialized)
@MainActor
struct SearchEngineSettingsTests {
    @Test func editingDefaultPreservesIdentityAndDisablingItSelectsAnotherEnabledEngine() throws {
        let original = SearchEngineConfiguration.builtIn
        var draft = EngineDraft(engine: original.defaultEngine)
        draft.name = "我的 Google"
        draft.keyword = "google"
        let renamed = try draft.applying(to: original).validated()
        #expect(renamed.defaultEngineID == "google")
        #expect(renamed.defaultEngine.keyword == "google")
        #expect(original.defaultEngine.keyword == "g")
        draft.isEnabled = false
        let disabled = try draft.applying(to: original).validated()
        #expect(disabled.defaultEngineID == "bing")
        #expect(!disabled.engines[0].isEnabled)
        #expect(disabled.engines.dropFirst() == original.engines.dropFirst())
    }

    @Test func editedFieldsAreLocalAndDirtyIncludingEnabledState() {
        let original = SearchEngineConfiguration.builtIn.defaultEngine
        for key in [\EngineDraft.name, \.keyword, \.urlTemplate] {
            var draft = EngineDraft(engine: original)
            #expect(!draft.isDirty)
            draft[keyPath: key] += "changed"
            #expect(draft.isDirty)
            #expect(original == SearchEngineConfiguration.builtIn.defaultEngine)
        }
        var draft = EngineDraft(engine: original)
        draft.isEnabled = false
        #expect(draft.isDirty)
    }

    @Test func rendersSettingsAndTemplateEditorInBothAppearances() throws {
        _ = NSApplication.shared
        let name = "dontstool.search.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SearchEngineStore(defaults: defaults)
        let websites = WebsiteShortcutStore(defaults: defaults)
        let draft = EngineDraft(engine: .init(id: "company", name: "公司文档", keyword: "wiki",
            urlTemplate: "https://docs.company.example/search?term={query}&scope=engineering"))
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try capture(ScrollView { SearchEnginesSettingsView(store: store, websites: websites).padding(16) },
                size: NSSize(width: 620, height: 540), name: "settings-\(suffix)", appearance: appearance)
            try capture(SearchEngineEditor(draft: draft, current: store.configuration,
                validate: { try $0.validated() }, save: { _ in }),
                size: NSSize(width: 600, height: 380), name: "editor-\(suffix)", appearance: appearance)
        }
    }

    private func capture(_ content: some View, size: NSSize, name: String, appearance: NSAppearance.Name) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: content.background(Theme.footerBase))
        window.contentView = view
        window.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/search-engine-previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
