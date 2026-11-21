import Foundation
import Testing
@testable import DontsToolCore

@Suite("PluginManager & Real Subprocess Transports")
@MainActor
struct PluginManagerTests {
    private func makeRootDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStores() -> (SettingsStore, PluginSettingsStore, UserDefaults, String) {
        let suite = "PluginManagerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults), PluginSettingsStore(defaults: defaults), defaults, suite)
    }

    private func writePlugin(
        id: String,
        name: String,
        keyword: String,
        mode: String = "oneshot",
        timeoutMs: Int = 1500,
        scriptBody: String,
        under directory: URL
    ) throws -> URL {
        let pluginDir = directory.appendingPathComponent(id, isDirectory: true)
        let binDir = pluginDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let runURL = binDir.appendingPathComponent("run")
        try Data(scriptBody.utf8).write(to: runURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runURL.path)

        let manifest = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "name": "\(name)",
          "version": "1.0.0",
          "keywords": ["\(keyword)"],
          "phase": "slow",
          "runsOnEmptyArgument": true,
          "runtime": {
            "mode": "\(mode)",
            "command": ["bin/run"],
            "timeoutMs": \(timeoutMs)
          },
          "permissions": ["clipboard.write", "toast"]
        }
        """
        try Data(manifest.utf8).write(to: pluginDir.appendingPathComponent("manifest.json"))
        return pluginDir
    }

    @Test func isolatesBrokenPluginAndAllowsUserPluginToOverrideBundled() async throws {
        let root = try makeRootDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

        let (settings, pluginSettings, defaults, suite) = makeStores()
        defer { defaults.removePersistentDomain(forName: suite) }

        let noopScript = "#!/bin/sh\necho '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"items\":[]}}'\n"
        _ = try writePlugin(
            id: "com.donts.sample",
            name: "Bundled Sample",
            keyword: "smp",
            scriptBody: noopScript,
            under: bundled
        )
        _ = try writePlugin(
            id: "com.donts.sample",
            name: "User Override Sample",
            keyword: "smp",
            scriptBody: noopScript,
            under: user
        )

        let brokenDir = user.appendingPathComponent("com.example.broken", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        try Data("{\"id\":\"com.example.broken\",\"name\":\"Broken\"}".utf8)
            .write(to: brokenDir.appendingPathComponent("manifest.json"))

        let registry = ToolRegistry(providers: [])
        let host = PluginHostContext(settings: settings, pluginSettings: pluginSettings)
        let manager = PluginManager(
            bundledDirectory: bundled,
            userDirectory: user,
            registry: registry,
            hostContext: host
        )
        manager.loadAll()

        #expect(registry.pluginProviders.count == 1)
        #expect(registry.pluginProviders[0].displayName == "User Override Sample")
        #expect(manager.records.contains { $0.id == "com.example.broken" && $0.errorMessage != nil })

        await manager.shutdown()
    }

    @Test func realOneShotSubprocessExecutesAndTerminatesOnTimeout() async throws {
        let root = try makeRootDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

        let (settings, pluginSettings, defaults, suite) = makeStores()
        defer { defaults.removePersistentDomain(forName: suite) }

        let script = #"""
        #!/bin/sh
        read -r line
        case "$line" in
          *'"slow"'*)
            sleep 5
            echo '{"jsonrpc":"2.0","id":1,"result":{"items":[]}}'
            ;;
          *)
            echo '{"jsonrpc":"2.0","id":1,"result":{"items":[{"title":"Shell Hit","canonicalKey":"sh:1","score":100,"actions":[{"id":"cp","title":"复制","effect":{"kind":"copy","value":"ok"}}]}]}}'
            ;;
        esac
        """#
        _ = try writePlugin(
            id: "com.example.oneshot",
            name: "Shell OneShot",
            keyword: "sh",
            mode: "oneshot",
            timeoutMs: 800,
            scriptBody: script,
            under: user
        )

        let registry = ToolRegistry(providers: [])
        let clipboard = MockClipboard()
        let host = PluginHostContext(settings: settings, pluginSettings: pluginSettings, clipboard: clipboard)
        let manager = PluginManager(userDirectory: user, registry: registry, hostContext: host)
        manager.loadAll()

        let provider = try #require(registry.pluginProviders.first as? SidecarProvider)
        let okItems = await provider.search(SearchContext(
            rawQuery: "sh fast",
            mode: .keyword(providerID: provider.id, keyword: "sh", argument: "fast")
        ))
        #expect(okItems.map(\.title) == ["Shell Hit"])
        let firstItem = try #require(okItems.first)
        try await firstItem.primaryAction?.run()
        #expect(clipboard.written == ["ok"])

        let timedOutItems = await provider.search(SearchContext(
            rawQuery: "sh slow",
            mode: .keyword(providerID: provider.id, keyword: "sh", argument: "slow")
        ))
        #expect(timedOutItems.isEmpty)
        #expect(provider.statusNotice == "Shell OneShot 响应超时")

        await manager.shutdown()
    }

    @Test func realDaemonSubprocessReusesPIDRestartsAfterCrashAndDeliversCancel() async throws {
        let root = try makeRootDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

        let (settings, pluginSettings, defaults, suite) = makeStores()
        defer { defaults.removePersistentDomain(forName: suite) }

        let cancelMarker = root.appendingPathComponent("cancel.log")
        let script = #"""
        #!/bin/sh
        CANCEL_FILE="\#(cancelMarker.path)"
        while IFS= read -r line; do
          case "$line" in
            *'"method":"shutdown"'*)
              exit 0
              ;;
            *'"method":"cancel"'*)
              printf '%s\n' "$line" >> "$CANCEL_FILE"
              ;;
            *'"method":"search"'*)
              id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
              case "$line" in
                *'"query":"crash"'*)
                  exit 42
                  ;;
                *'"query":"hang"'*)
                  sleep 2 &
                  ;;
                *)
                  printf '{"jsonrpc":"2.0","id":%s,"result":{"items":[{"title":"PID %s","canonicalKey":"daemon:pid","score":100,"actions":[]}]}}\n' "$id" "$$"
                  ;;
              esac
              ;;
          esac
        done
        """#
        _ = try writePlugin(
            id: "com.example.daemon",
            name: "Shell Daemon",
            keyword: "dm",
            mode: "daemon",
            timeoutMs: 1000,
            scriptBody: script,
            under: user
        )

        let registry = ToolRegistry(providers: [])
        let host = PluginHostContext(settings: settings, pluginSettings: pluginSettings)
        let manager = PluginManager(userDirectory: user, registry: registry, hostContext: host)
        manager.loadAll()

        let provider = try #require(registry.pluginProviders.first as? SidecarProvider)
        let first = await provider.search(SearchContext(
            rawQuery: "dm a",
            mode: .keyword(providerID: provider.id, keyword: "dm", argument: "a")
        ))
        let second = await provider.search(SearchContext(
            rawQuery: "dm b",
            mode: .keyword(providerID: provider.id, keyword: "dm", argument: "b")
        ))
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].title == second[0].title)
        #expect(first[0].title.hasPrefix("PID "))

        // Trigger a hanging request and cancel its Task to verify cancel notification delivery
        let hangTask = Task {
            await provider.search(SearchContext(
                rawQuery: "dm hang",
                mode: .keyword(providerID: provider.id, keyword: "dm", argument: "hang")
            )).count
        }
        try? await Task.sleep(for: .milliseconds(50))
        hangTask.cancel()
        let cancelledCount = await hangTask.value
        #expect(cancelledCount == 0)
        try? await Task.sleep(for: .milliseconds(80))
        let cancelLog = (try? String(contentsOf: cancelMarker, encoding: .utf8)) ?? ""
        #expect(cancelLog.contains("\"method\":\"cancel\""))

        // Trigger an unexpected crash, then verify automatic restart with a new PID
        let crashed = await provider.search(SearchContext(
            rawQuery: "dm crash",
            mode: .keyword(providerID: provider.id, keyword: "dm", argument: "crash")
        ))
        #expect(crashed.isEmpty)
        #expect(provider.statusNotice != nil)

        let restarted = await provider.search(SearchContext(
            rawQuery: "dm ok",
            mode: .keyword(providerID: provider.id, keyword: "dm", argument: "ok")
        ))
        #expect(restarted.count == 1)
        #expect(restarted[0].title != first[0].title)

        await manager.shutdown()
    }
}
