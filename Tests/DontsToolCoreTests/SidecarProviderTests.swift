import Foundation
import os
import Testing
@testable import DontsToolCore

private final class MockPluginTransport: PluginTransport, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var requests: [(method: String, paramsData: Data)] = []
        var handler: (@Sendable (String, Data) async throws -> Data)?
        var shutdownCount = 0
    }

    var requests: [(method: String, paramsData: Data)] {
        state.withLock(\.requests)
    }

    var shutdownCount: Int {
        state.withLock(\.shutdownCount)
    }

    func setHandler(_ handler: @escaping @Sendable (String, Data) async throws -> Data) {
        state.withLock { $0.handler = handler }
    }

    func request(method: String, paramsData: Data, timeout: Duration) async throws -> Data {
        let handler = state.withLock { state -> (@Sendable (String, Data) async throws -> Data)? in
            state.requests.append((method, paramsData))
            return state.handler
        }
        guard let handler else {
            return try JSONEncoder().encode(PluginRPCResponse(
                id: 1,
                result: PluginSearchResultDTO(items: [])
            ))
        }
        return try await handler(method, paramsData)
    }

    func shutdown() async {
        state.withLock { $0.shutdownCount += 1 }
    }

    func shutdownSync() {
        state.withLock { $0.shutdownCount += 1 }
    }
}

@MainActor
private final class SpyFeedback: FeedbackProviding {
    var messages: [String] = []
    func show(_ message: String) { messages.append(message) }
}

@MainActor
private final class SpyURLOpener: URLOpening {
    var opened: [URL] = []
    func open(_ url: URL) throws { opened.append(url) }
}

@MainActor
private final class SpyAppLauncher: AppLaunching {
    var openedApplications: [URL] = []
    var openedFiles: [URL] = []
    var revealedInFinder: [URL] = []
    var quitApplications: [URL] = []

    func openApplication(at url: URL) async throws {
        openedApplications.append(url)
    }

    func openFile(at url: URL) throws {
        openedFiles.append(url)
    }

    func revealInFinder(_ url: URL) {
        revealedInFinder.append(url)
    }

    func quitApplication(at url: URL) -> Bool {
        quitApplications.append(url)
        return true
    }
}

@Suite("SidecarProvider")
@MainActor
struct SidecarProviderTests {
    private func makeStores() -> (SettingsStore, PluginSettingsStore, UserDefaults, String) {
        let suite = "SidecarProviderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults), PluginSettingsStore(defaults: defaults), defaults, suite)
    }

    private func makeManifest(
        id: String = "com.example.demo",
        keywords: [String] = ["demo"],
        globalAliases: [String] = ["demo", "演示"],
        permissions: Set<PluginPermission> = [.clipboardWrite, .openURL, .prefill, .toast, .refresh, .secrets],
        preferences: [PluginPreferenceSpec] = []
    ) -> ResolvedPluginManifest {
        ResolvedPluginManifest(
            id: id,
            name: "Demo Plugin",
            version: "1.0.0",
            description: "Demo",
            minHostVersion: nil,
            origin: .user,
            directoryURL: URL(fileURLWithPath: "/tmp/demo-plugin"),
            keywords: keywords,
            supportsGlobalSearch: false,
            globalAliases: globalAliases,
            phase: .slow,
            runsOnEmptyArgument: true,
            priority: 30,
            iconPath: nil,
            legacyProviderID: nil,
            homeEntry: ResolvedPluginHomeEntry(
                canonicalKey: "demo:entry",
                title: "Demo Plugin",
                subtitle: "输入 demo 搜索",
                icon: .symbol(name: "puzzlepiece.extension", tint: .teal),
                score: 810
            ),
            runtimeMode: .oneshot,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            timeout: .seconds(1),
            idleTimeout: .seconds(60),
            permissions: permissions,
            preferences: preferences,
            uiEntryURL: nil
        )
    }

    @Test func homeEntryAndGlobalAliasesAvoidIPCAndYieldUnavailableKeywords() async throws {
        let (settings, pluginSettings, defaults, suite) = makeStores()
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefiller = MockPrefiller()
        let transport = MockPluginTransport()
        let host = PluginHostContext(
            settings: settings,
            pluginSettings: pluginSettings,
            prefill: prefiller,
            unavailableKeywords: { ["demo"] }
        )

        let manifest = makeManifest(keywords: ["demo", "dm"], globalAliases: ["demo", "演示"])
        let provider = SidecarProvider(manifest: manifest, host: host, transport: transport)

        #expect(provider.keywords == ["dm"])
        let home = try #require(provider.homeToolEntry())
        #expect(home.keyword == "dm")
        try await home.primaryAction?.run()
        #expect(prefiller.queries == ["dm "])

        let discovery = await provider.search(SearchContext(rawQuery: "演示", mode: .global))
        #expect(discovery.count == 1)
        #expect(transport.requests.isEmpty)
    }

    @Test func passesIsolatedSecretsAndExecutesDirectAndCallbackActions() async throws {
        let (settings, pluginSettings, defaults, suite) = makeStores()
        defer { defaults.removePersistentDomain(forName: suite) }

        let secrets = MemorySecretStore()
        secrets.setSecret("host-translation-secret", for: SecretAccount.translationAPIKey)
        pluginSettings.setSecret("plugin-only-token", forPluginID: "com.example.demo", key: "apiToken", using: secrets)
        pluginSettings.setPreferenceValue("https://jira.example.com", pluginID: "com.example.demo", key: "baseUrl")

        let clipboard = MockClipboard()
        let feedback = SpyFeedback()
        let urlOpener = SpyURLOpener()
        var refreshCount = 0

        let transport = MockPluginTransport()
        transport.setHandler { method, paramsData in
            if method == "search" {
                let params = try JSONDecoder().decode(PluginSearchParams.self, from: paramsData)
                #expect(params.preferences["baseUrl"] == "https://jira.example.com")
                #expect(params.preferences["apiToken"] == "plugin-only-token")
                #expect(!params.preferences.values.contains("host-translation-secret"))

                let result = PluginSearchResultDTO(items: [
                    PluginSearchItemDTO(
                        title: "PROJ-42",
                        subtitle: "修复登录问题",
                        score: 1200,
                        canonicalKey: "jira:42",
                        icon: PluginIconDTO(kind: "symbol", value: "ticket", tint: "blue"),
                        actions: [
                            PluginActionDTO(
                                id: "open",
                                title: "打开链接",
                                presentation: "dismissThenRun",
                                effect: PluginActionEffectDTO(kind: "openURL", value: "https://jira.example.com/browse/PROJ-42")
                            ),
                            PluginActionDTO(
                                id: "copy",
                                title: "复制单号",
                                presentation: "keepPanelOpen",
                                callback: true,
                                payload: ["key": "PROJ-42"]
                            )
                        ]
                    )
                ])
                return try JSONEncoder().encode(PluginRPCResponse(id: 1, result: result))
            }
            if method == "execute" {
                let params = try JSONDecoder().decode(PluginExecuteParams.self, from: paramsData)
                #expect(params.actionId == "copy")
                let result = PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "copy", value: params.payload["key"]),
                    toast: "已复制单号",
                    refresh: true
                )
                return try JSONEncoder().encode(PluginRPCResponse(id: 2, result: result))
            }
            throw PluginTransportError.invalidResponse("unexpected")
        }

        let host = PluginHostContext(
            settings: settings,
            pluginSettings: pluginSettings,
            clipboard: clipboard,
            urlOpener: urlOpener,
            feedback: feedback,
            secrets: secrets,
            refreshSearch: { refreshCount += 1 }
        )

        let manifest = makeManifest(preferences: [
            PluginPreferenceSpec(key: "baseUrl", type: "string", title: "地址"),
            PluginPreferenceSpec(key: "apiToken", type: "secret", title: "Token"),
            PluginPreferenceSpec(key: SecretAccount.translationAPIKey, type: "secret", title: "AttemptLeak")
        ])
        let provider = SidecarProvider(manifest: manifest, host: host, transport: transport)

        let items = await provider.search(SearchContext(
            rawQuery: "demo 42",
            mode: .keyword(providerID: provider.id, keyword: "demo", argument: "42")
        ))
        #expect(items.count == 1)
        try await items[0].actions[0].run()
        #expect(urlOpener.opened.map(\.absoluteString) == ["https://jira.example.com/browse/PROJ-42"])

        try await items[0].actions[1].run()
        #expect(clipboard.written == ["PROJ-42"])
        #expect(feedback.messages == ["已复制单号"])
        #expect(refreshCount == 1)
    }

    @Test func enforcesPermissionChecksAndIsolatesTimeouts() async throws {
        let (settings, pluginSettings, defaults, suite) = makeStores()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clipboard = MockClipboard()
        let urlOpener = SpyURLOpener()
        let transport = MockPluginTransport()
        transport.setHandler { _, _ in
            let result = PluginSearchResultDTO(items: [
                PluginSearchItemDTO(
                    title: "Restricted",
                    canonicalKey: "restricted",
                    actions: [
                        PluginActionDTO(
                            id: "copy",
                            title: "复制",
                            effect: PluginActionEffectDTO(kind: "copy", value: "secret")
                        ),
                        PluginActionDTO(
                            id: "bad-url",
                            title: "非法链接",
                            effect: PluginActionEffectDTO(kind: "openURL", value: "file:///etc/passwd")
                        )
                    ]
                )
            ])
            return try JSONEncoder().encode(PluginRPCResponse(id: 1, result: result))
        }

        let host = PluginHostContext(
            settings: settings,
            pluginSettings: pluginSettings,
            clipboard: clipboard,
            urlOpener: urlOpener
        )
        // Only grant openURL, not clipboardWrite
        let provider = SidecarProvider(
            manifest: makeManifest(permissions: [.openURL]),
            host: host,
            transport: transport
        )

        let items = await provider.search(SearchContext(
            rawQuery: "demo x",
            mode: .keyword(providerID: provider.id, keyword: "demo", argument: "x")
        ))
        #expect(items.count == 1)

        await #expect(throws: PluginHostError.permissionDenied(.clipboardWrite, pluginID: "com.example.demo")) {
            try await items[0].actions[0].run()
        }
        #expect(clipboard.written.isEmpty)

        await #expect(throws: PluginHostError.invalidActionTarget("file:///etc/passwd")) {
            try await items[0].actions[1].run()
        }
        #expect(urlOpener.opened.isEmpty)

        // Timeout degrades into statusNotice without throwing
        transport.setHandler { _, _ in
            throw PluginTransportError.timedOut
        }
        let timedOutItems = await provider.search(SearchContext(
            rawQuery: "demo slow",
            mode: .keyword(providerID: provider.id, keyword: "demo", argument: "slow")
        ))
        #expect(timedOutItems.isEmpty)
        #expect(provider.statusNotice == "Demo Plugin 响应超时")
    }

    @Test func mapsGroupFileActionsHostContextAndTerminalAppEffects() async throws {
        let (settings, pluginSettings, defaults, suite) = makeStores()
        defer { defaults.removePersistentDomain(forName: suite) }

        settings.setPreferredTerminalBundleID("com.mitchellh.ghostty")
        let appLauncher = SpyAppLauncher()
        var openedInTerminal: [URL] = []

        let transport = MockPluginTransport()
        transport.setHandler { method, paramsData in
            if method == "search" {
                let params = try JSONDecoder().decode(PluginSearchParams.self, from: paramsData)
                #expect(params.hostContext?["preferredTerminalBundleID"] == "com.mitchellh.ghostty")
                #expect(params.hostContext?["hostVersion"] == "0.2.14")

                let result = PluginSearchResultDTO(items: [
                    PluginSearchItemDTO(
                        title: "README.md",
                        subtitle: "~/Desktop",
                        score: 900,
                        canonicalKey: "file:/tmp/README.md",
                        icon: PluginIconDTO(kind: "file", value: "/tmp/README.md"),
                        actions: [
                            PluginActionDTO(
                                id: "reveal",
                                title: "在访达中显示",
                                symbol: "folder",
                                effect: PluginActionEffectDTO(kind: "revealInFinder", value: "/tmp/README.md"),
                                fileAction: "reveal"
                            ),
                            PluginActionDTO(
                                id: "copyPath",
                                title: "复制路径",
                                symbol: "doc.on.doc",
                                effect: PluginActionEffectDTO(kind: "copy", value: "/tmp/README.md"),
                                fileAction: "copyPath"
                            ),
                            PluginActionDTO(
                                id: "terminal",
                                title: "在终端打开",
                                symbol: "terminal",
                                effect: PluginActionEffectDTO(kind: "openInTerminal", value: "/tmp/README.md")
                            ),
                            PluginActionDTO(
                                id: "launchApp",
                                title: "打开应用",
                                callback: true,
                                payload: ["appPath": "/Applications/IntelliJ IDEA.app"]
                            )
                        ],
                        group: "file"
                    ),
                    PluginSearchItemDTO(
                        title: "Web Hit",
                        canonicalKey: "web:1",
                        actions: [],
                        group: "web"
                    ),
                    PluginSearchItemDTO(
                        title: "Shortcut Hit",
                        canonicalKey: "shortcut:1",
                        actions: [],
                        group: "shortcut"
                    ),
                    PluginSearchItemDTO(
                        title: "Disallowed App Group",
                        canonicalKey: "spoof:app",
                        actions: [],
                        group: "app"
                    )
                ])
                return try JSONEncoder().encode(PluginRPCResponse(id: 1, result: result))
            }

            if method == "execute" {
                let params = try JSONDecoder().decode(PluginExecuteParams.self, from: paramsData)
                #expect(params.actionId == "launchApp")
                #expect(params.hostContext?["preferredTerminalBundleID"] == "com.mitchellh.ghostty")
                #expect(params.hostContext?["hostVersion"] == "0.2.14")

                let result = PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(
                        kind: "openApplication",
                        value: params.payload["appPath"]
                    )
                )
                return try JSONEncoder().encode(PluginRPCResponse(id: 2, result: result))
            }
            throw PluginTransportError.invalidResponse("unexpected")
        }

        let host = PluginHostContext(
            settings: settings,
            pluginSettings: pluginSettings,
            appLauncher: appLauncher,
            openInTerminal: { url in
                openedInTerminal.append(url)
            },
            hostVersion: "0.2.14"
        )

        let manifest = makeManifest(permissions: [
            .clipboardWrite,
            .revealInFinder,
            .openTerminal,
            .openApplication
        ])
        let provider = SidecarProvider(manifest: manifest, host: host, transport: transport)

        let items = await provider.search(SearchContext(
            rawQuery: "demo readme",
            mode: .keyword(providerID: provider.id, keyword: "demo", argument: "readme")
        ))
        #expect(items.count == 4)
        #expect(items[0].group == .file)
        #expect(items[1].group == .web)
        #expect(items[2].group == .shortcut)
        #expect(items[3].group == .tool)

        let revealAction = try #require(items[0].fileAction(.reveal))
        let copyAction = try #require(items[0].fileAction(.copyPath))
        #expect(revealAction.id == "reveal")
        #expect(copyAction.id == "copyPath")

        try await revealAction.run()
        #expect(appLauncher.revealedInFinder == [URL(fileURLWithPath: "/tmp/README.md")])

        try await items[0].actions[2].run()
        #expect(openedInTerminal == [URL(fileURLWithPath: "/tmp/README.md")])

        try await items[0].actions[3].run()
        #expect(appLauncher.openedApplications == [URL(fileURLWithPath: "/Applications/IntelliJ IDEA.app")])

        // Verify openTerminal / openApplication permission denial
        let restrictedProvider = SidecarProvider(
            manifest: makeManifest(permissions: []),
            host: host,
            transport: transport
        )
        let restrictedItems = await restrictedProvider.search(SearchContext(
            rawQuery: "demo readme",
            mode: .keyword(providerID: restrictedProvider.id, keyword: "demo", argument: "readme")
        ))
        await #expect(throws: PluginHostError.permissionDenied(.openTerminal, pluginID: "com.example.demo")) {
            try await restrictedItems[0].actions[2].run()
        }
        await #expect(throws: PluginHostError.permissionDenied(.openApplication, pluginID: "com.example.demo")) {
            try await restrictedItems[0].actions[3].run()
        }
    }
}
