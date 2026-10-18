import Foundation
import Testing
@testable import DontsToolCore

@MainActor
final class MockAppLauncher: AppLaunching {
    var openedApplications: [URL] = []
    var openedFiles: [URL] = []
    var revealed: [URL] = []
    var error: Error?

    func openApplication(at url: URL) async throws {
        if let error { throw error }
        openedApplications.append(url)
    }

    func openFile(at url: URL) throws {
        if let error { throw error }
        openedFiles.append(url)
    }

    func revealInFinder(_ url: URL) {
        revealed.append(url)
    }
}

@MainActor
final class MockFeedback: FeedbackProviding {
    var messages: [String] = []
    func show(_ message: String) { messages.append(message) }
}

@Suite("AppProvider")
@MainActor
struct AppProviderTests {
    private func makeEntry(_ name: String, path: String) -> AppEntry {
        AppEntry(
            id: path,
            displayName: name,
            bundleID: nil,
            url: URL(fileURLWithPath: path),
            modifiedAt: nil
        )
    }

    @Test func fuzzyMatchesAndUsesRecencyBoost() async throws {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let usage = UsageStore(defaults: defaults, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        usage.recordUse(of: "/Applications/Chrome.app", at: Date(timeIntervalSince1970: 1_700_000_000))
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([
            makeEntry("Chrome", path: "/Applications/Chrome.app"),
            makeEntry("Chromium", path: "/Applications/Chromium.app")
        ])

        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: usage,
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )
        let items = await provider.search(SearchContext(rawQuery: "chr", mode: .global))
        #expect(items.first?.title == "Chrome")
    }

    @Test func primaryActionLaunchesAndRecordsUse() async throws {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let usage = UsageStore(defaults: defaults, now: { Date() })
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: "/Applications/Safari.app")])
        let launcher = MockAppLauncher()
        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: usage,
            launcher: launcher,
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "saf", mode: .global))
        try await items[0].primaryAction?.run()
        #expect(launcher.openedApplications.map(\.path) == ["/Applications/Safari.app"])
        #expect(usage.record(for: "/Applications/Safari.app")?.count == 1)
    }

    @Test func disabledProviderReturnsNoItems() async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setProviderEnabled("app", to: false)
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: "/Applications/Safari.app")])
        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "saf", mode: .global))
        #expect(items.isEmpty)
    }
}
