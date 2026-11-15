import Foundation
import Testing
@testable import DontsToolCore

@MainActor
private final class ProjectLauncherSpy: IDEProjectOpening {
    var opened: [(URL, URL)] = []
    var revealed: [URL] = []
    func openProject(at project: URL, using application: URL) async throws { opened.append((project, application)) }
    func revealInFinder(_ url: URL) { revealed.append(url) }
}

private actor PausingProjectDiscovery: IDEProjectDiscovering {
    private let base: IDEProjectDiscovery
    private var validationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var validation: CheckedContinuation<Bool, Never>?

    init(base: IDEProjectDiscovery) { self.base = base }

    func discover(applications: [IDEApplicationCandidate], manualPath: String?) async -> IDEProjectDiscoveryResult {
        await base.discover(applications: applications, manualPath: manualPath)
    }

    func isLocalDirectory(_ url: URL) async -> Bool {
        validationStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { validation = $0 }
    }

    func waitForValidation() async {
        if validationStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishValidation() { validation?.resume(returning: true); validation = nil }
}

@Suite("IDEA project provider")
@MainActor
struct IDEProjectProviderTests {
    @Test func keywordOnlySearchFiltersProjectsAndOpensWithSelectedIDE() async throws {
        let fixture = try IDEProjectFixture()
        defer { fixture.remove() }
        let exact = try fixture.project("kb")
        let fuzzy = try fixture.project("DontsKb-server")
        try fixture.history(version: "2026.3", paths: [(fuzzy.path, 999), (exact.path, 1)])
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setProviderEnabled("ideaProjects", to: true)
        let usage = UsageStore(defaults: defaults)
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([AppEntry(id: fixture.app.path, displayName: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij", url: fixture.app, modifiedAt: nil)])
        let launcher = ProjectLauncherSpy()
        let clipboard = MockClipboard()
        let provider = IDEProjectProvider(index: index, settings: settings, usage: usage, launcher: launcher, feedback: MockFeedback(), clipboard: clipboard, discovery: IDEProjectDiscovery(homeDirectory: fixture.root, jetBrainsDirectory: fixture.config, applicationRoots: []))
        #expect(await provider.search(SearchContext(rawQuery: "idea", mode: .global)).isEmpty)
        #expect(await provider.search(SearchContext(rawQuery: "open kb", mode: .keyword(providerID: "quickOpen", keyword: "open", argument: "kb"))).isEmpty)
        let all = await provider.search(context(""))
        #expect(all.map(\.title) == ["DontsKb-server", "kb"])
        let items = await provider.search(context("kb"))
        #expect(items.map(\.title) == ["kb", "DontsKb-server"])
        try #require(items.count == 2)
        #expect(items[0].subtitle?.contains("IntelliJ IDEA") == true)
        #expect(items[0].actions.count == 3)
        try await items[0].primaryAction?.run()
        #expect(launcher.opened.first?.0.path == exact.path)
        #expect(launcher.opened.first?.1.path == fixture.app.path)
        #expect(usage.record(for: items[0].canonicalKey)?.count == 1)
        try await items[0].secondaryAction?.run()
        #expect(launcher.revealed.map(\.path) == [exact.path])
        try await items[0].actions.last?.run()
        #expect(clipboard.written == [exact.path])
        settings.setProviderEnabled("ideaProjects", to: false)
        #expect(await provider.search(context("kb")).isEmpty)
    }

    @Test func acceptsManualDirectoryAndRevalidatesBeforeOpeningDeletedProject() async throws {
        let fixture = try IDEProjectFixture()
        defer { fixture.remove() }
        let manual = try fixture.project("Manual Project")
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([AppEntry(id: fixture.app.path, displayName: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij", url: fixture.app, modifiedAt: nil)])
        let launcher = ProjectLauncherSpy()
        let feedback = MockFeedback()
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setProviderEnabled("ideaProjects", to: true)
        let provider = IDEProjectProvider(index: index, settings: settings, usage: UsageStore(defaults: defaults), launcher: launcher, feedback: feedback, discovery: IDEProjectDiscovery(homeDirectory: fixture.root, jetBrainsDirectory: fixture.config, applicationRoots: []))
        let items = await provider.search(context(manual.path))
        #expect(items.first?.title == "Manual Project")
        try FileManager.default.removeItem(at: manual)
        try await items.first?.primaryAction?.run()
        #expect(launcher.opened.isEmpty)
        #expect(feedback.messages.count == 1)
    }

    @Test func missingIDEProducesHintInsteadOfOpenAction() async {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setProviderEnabled("ideaProjects", to: true)
        let provider = IDEProjectProvider(index: AppIndex(scanner: AppScanner(roots: [])), settings: settings, usage: UsageStore(defaults: defaults), launcher: ProjectLauncherSpy(), feedback: MockFeedback(), discovery: IDEProjectDiscovery(applicationRoots: []))
        let items = await provider.search(context(""))
        #expect(items.count == 1)
        #expect(items.first?.primaryAction?.presentation == .keepPanelOpen)
        #expect(provider.statusNotice != nil)
    }

    @Test(arguments: ["idea.project.open", "idea.project.reveal", "idea.project.copyPath"])
    func disablingProviderRevokesPreviouslyGeneratedActions(actionID: String) async throws {
        let fixture = try IDEProjectFixture()
        defer { fixture.remove() }
        let project = try fixture.project("Project")
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setProviderEnabled("ideaProjects", to: true)
        let usage = UsageStore(defaults: defaults)
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([AppEntry(id: fixture.app.path, displayName: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij", url: fixture.app, modifiedAt: nil)])
        let launcher = ProjectLauncherSpy()
        let clipboard = MockClipboard()
        let provider = IDEProjectProvider(index: index, settings: settings, usage: usage, launcher: launcher, feedback: MockFeedback(), clipboard: clipboard, discovery: IDEProjectDiscovery(homeDirectory: fixture.root, jetBrainsDirectory: fixture.config, applicationRoots: []))
        let items = await provider.search(context(project.path))
        let item = try #require(items.first)
        let action = try #require(item.actions.first { $0.id == actionID })
        settings.setProviderEnabled("ideaProjects", to: false)

        try await action.run()

        #expect(launcher.opened.isEmpty)
        #expect(launcher.revealed.isEmpty)
        #expect(clipboard.written.isEmpty)
        #expect(usage.record(for: item.canonicalKey) == nil)
    }

    @Test(arguments: ["disable", "cancel"])
    func openingStopsWhenAuthorizationChangesDuringDirectoryValidation(change: String) async throws {
        let fixture = try IDEProjectFixture()
        defer { fixture.remove() }
        let project = try fixture.project("Project")
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setProviderEnabled("ideaProjects", to: true)
        let usage = UsageStore(defaults: defaults)
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([AppEntry(id: fixture.app.path, displayName: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij", url: fixture.app, modifiedAt: nil)])
        let launcher = ProjectLauncherSpy()
        let feedback = MockFeedback()
        let discovery = PausingProjectDiscovery(base: IDEProjectDiscovery(homeDirectory: fixture.root, jetBrainsDirectory: fixture.config, applicationRoots: []))
        let provider = IDEProjectProvider(index: index, settings: settings, usage: usage, launcher: launcher, feedback: feedback, discovery: discovery)
        let items = await provider.search(context(project.path))
        let item = try #require(items.first)
        let action = try #require(item.primaryAction)
        let pending = Task { try await action.run() }
        await discovery.waitForValidation()
        if change == "disable" { settings.setProviderEnabled("ideaProjects", to: false) }
        else { pending.cancel() }
        await discovery.finishValidation()
        try await pending.value

        #expect(launcher.opened.isEmpty)
        #expect(usage.record(for: item.canonicalKey) == nil)
        #expect(feedback.messages.isEmpty)
    }

    private func context(_ argument: String) -> SearchContext {
        SearchContext(rawQuery: "idea \(argument)", mode: .keyword(providerID: "ideaProjects", keyword: "idea", argument: argument))
    }
}
