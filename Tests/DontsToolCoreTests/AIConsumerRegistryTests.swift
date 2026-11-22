import Foundation
import Testing
@testable import DontsToolCore

@Suite("AIConsumerRegistry")
@MainActor
struct AIConsumerRegistryTests {
    private func makeStores() -> (SettingsStore, PluginSettingsStore, UserDefaults, String) {
        let suite = "AIConsumerRegistryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults, systemLanguageCode: "zh"), PluginSettingsStore(defaults: defaults), defaults, suite)
    }

    private func writePlugin(
        id: String,
        name: String,
        description: String? = nil,
        keyword: String,
        permissions: [String],
        under directory: URL
    ) throws -> URL {
        let pluginDir = directory.appendingPathComponent(id, isDirectory: true)
        let binDir = pluginDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let runURL = binDir.appendingPathComponent("run")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runURL.path)

        var object: [String: Any] = [
            "schemaVersion": 1,
            "id": id,
            "name": name,
            "version": "1.0.0",
            "keywords": [keyword],
            "phase": "slow",
            "runsOnEmptyArgument": true,
            "runtime": [
                "mode": "oneshot",
                "command": ["bin/run"],
                "timeoutMs": 1500
            ],
            "permissions": permissions
        ]
        if let description {
            object["description"] = description
        }
        let manifestData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))
        return pluginDir
    }

    @Test func builtInTranslationConsumerTracksEnabledStateAndPreservesBinding() {
        let (settings, _, defaults, suite) = makeStores()
        defer { defaults.removePersistentDomain(forName: suite) }

        let profile = AIModelProfile(
            id: "prof-trans",
            name: "Gemini 翻译",
            format: .gemini,
            baseURL: "https://generativelanguage.googleapis.com",
            model: "gemini-2.5-flash"
        )
        let fallback = AIModelProfile(
            id: "prof-default",
            name: "默认模型",
            format: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1-mini"
        )
        settings.upsertAIModelProfile(fallback, makeDefault: true)
        settings.upsertAIModelProfile(profile)
        settings.setAIModelProfileID(profile.id, forConsumerID: AIConsumerID.translation)

        let registry = AIConsumerRegistry()
        registry.registerBuiltInTranslationConsumer(settings: settings)

        #expect(registry.consumers.map(\.id) == [AIConsumerID.translation])
        #expect(registry.consumers.first?.title == "翻译与划词")

        // Closing both translation provider and selection translation hides the row while preserving saved binding
        settings.setProviderEnabled(ProviderID.translation.rawValue, to: false)
        settings.setSelectionTranslationEnabled(false)
        #expect(registry.consumers.isEmpty)
        #expect(settings.aiModelProfileID(forConsumerID: AIConsumerID.translation) == profile.id)

        // Enabling selection translation alone brings back the consumer with previous binding intact
        settings.setSelectionTranslationEnabled(true)
        #expect(registry.consumers.map(\.id) == [AIConsumerID.translation])
        #expect(settings.aiModelProfileID(forConsumerID: AIConsumerID.translation) == profile.id)

        // Turning off selection translation but enabling translation provider keeps it visible
        settings.setSelectionTranslationEnabled(false)
        settings.setProviderEnabled(ProviderID.translation.rawValue, to: true)
        #expect(registry.consumers.map(\.id) == [AIConsumerID.translation])
    }

    @Test func pluginConsumersTrackLoadedEnabledOpenAIPluginsAndPreserveBindings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIConsumerPluginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

        let (settings, pluginSettings, defaults, suite) = makeStores()
        defer { defaults.removePersistentDomain(forName: suite) }

        let quickAIDir = try writePlugin(
            id: "com.donts.quick-ai",
            name: "AI 快问",
            description: "唤起原生流式 AI 对话窗口",
            keyword: "ai",
            permissions: ["openAI", "prefill"],
            under: user
        )
        _ = try writePlugin(
            id: "com.example.reviewer",
            name: "代码审查",
            description: "分析工作区 diff",
            keyword: "rev",
            permissions: ["openAI"],
            under: user
        )
        _ = try writePlugin(
            id: "com.example.plain",
            name: "普通工具插件",
            keyword: "pln",
            permissions: ["clipboard.write"],
            under: user
        )
        let brokenDir = user.appendingPathComponent("com.example.broken-ai", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        try Data("{\"id\":\"com.example.broken-ai\"}".utf8).write(to: brokenDir.appendingPathComponent("manifest.json"))

        let host = PluginHostContext(
            settings: settings,
            pluginSettings: pluginSettings,
            hostVersion: "0.4.3"
        )
        let manager = PluginManager(
            bundledDirectory: bundled,
            userDirectory: user,
            registry: ToolRegistry(providers: []),
            hostContext: host
        )
        manager.loadAll()

        let consumerRegistry = AIConsumerRegistry()
        consumerRegistry.registerPluginConsumers(
            pluginManager: manager,
            pluginSettings: pluginSettings,
            settings: settings
        )

        let expectedIDs = [
            AIConsumerID.plugin("com.donts.quick-ai"),
            AIConsumerID.plugin("com.example.reviewer")
        ]
        #expect(Set(consumerRegistry.consumers.map(\.id)) == Set(expectedIDs))

        let pA = AIModelProfile(id: "p-a", name: "Flash", format: .gemini, baseURL: "https://generativelanguage.googleapis.com", model: "gemini-2.5-flash")
        let pB = AIModelProfile(id: "p-b", name: "Pro", format: .openAIResponses, baseURL: "https://api.openai.com/v1", model: "gpt-4.1")
        settings.upsertAIModelProfile(pA, makeDefault: true)
        settings.upsertAIModelProfile(pB)
        settings.setAIModelProfileID(pA.id, forConsumerID: AIConsumerID.plugin("com.donts.quick-ai"))
        settings.setAIModelProfileID(pB.id, forConsumerID: AIConsumerID.plugin("com.example.reviewer"))

        // Disabling a plugin removes it from UI registration while preserving its saved binding
        pluginSettings.setPluginEnabled("com.example.reviewer", to: false)
        #expect(consumerRegistry.consumers.map(\.id) == [AIConsumerID.plugin("com.donts.quick-ai")])
        #expect(settings.aiModelProfileID(forConsumerID: AIConsumerID.plugin("com.example.reviewer")) == pB.id)

        // Re-enabling restores slot and binding
        pluginSettings.setPluginEnabled("com.example.reviewer", to: true)
        #expect(Set(consumerRegistry.consumers.map(\.id)) == Set(expectedIDs))

        // Uninstalling quick-ai removes it from registry after reload while preserving saved binding for future reinstall
        try FileManager.default.removeItem(at: quickAIDir)
        manager.reload()
        #expect(consumerRegistry.consumers.map(\.id) == [AIConsumerID.plugin("com.example.reviewer")])
        #expect(settings.aiModelProfileID(forConsumerID: AIConsumerID.plugin("com.donts.quick-ai")) == pA.id)

        // Re-installing brings quick-ai slot back with original binding
        _ = try writePlugin(
            id: "com.donts.quick-ai",
            name: "AI 快问",
            description: "唤起原生流式 AI 对话窗口",
            keyword: "ai",
            permissions: ["openAI", "prefill"],
            under: user
        )
        manager.reload()
        #expect(Set(consumerRegistry.consumers.map(\.id)) == Set(expectedIDs))
        #expect(settings.resolvedAIConfiguration(forConsumerID: AIConsumerID.plugin("com.donts.quick-ai")).profileID == pA.id)
    }
}
