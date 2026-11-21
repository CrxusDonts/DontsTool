import Foundation
import Testing
@testable import DontsToolCore

@Suite("PluginManifest")
struct PluginManifestTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func loadsValidUserManifestAndClampsPriorityAndTimeout() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bin = dir.appendingPathComponent("bin/run")
        try makeExecutable(at: bin)
        let icon = dir.appendingPathComponent("icon.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: icon)

        let json = """
        {
          "schemaVersion": 1,
          "id": "com.example.jira",
          "name": "Jira 搜索",
          "version": "1.2.0",
          "description": "查询 Jira 单号",
          "keywords": ["  JIRA ", "jira", "jr"],
          "phase": "fast",
          "priority": 999,
          "icon": "icon.png",
          "runtime": {
            "mode": "oneshot",
            "command": ["bin/run", "--flag"],
            "timeoutMs": 99999,
            "idleTimeoutSec": 99999
          },
          "permissions": ["openURL", "clipboard.write"]
        }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("manifest.json"))

        let resolved = try PluginManifestLoader.load(from: dir, origin: .user)
        #expect(resolved.id == "com.example.jira")
        #expect(resolved.keywords == ["jira", "jr"])
        #expect(resolved.phase == .fast)
        #expect(resolved.priority == 50)
        #expect(resolved.timeout == .milliseconds(2000))
        #expect(resolved.idleTimeout == .seconds(3600))
        #expect(resolved.arguments == ["--flag"])
        #expect(resolved.executableURL.standardizedFileURL.path == bin.standardizedFileURL.path)
        #expect(resolved.iconPath == icon.standardizedFileURL.path)
        #expect(resolved.permissions == [.openURL, .clipboardWrite])
    }

    @Test func rejectsPathTraversalInCommandIconAndHomeEntry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(at: dir.appendingPathComponent("bin/run"))

        let badCommand = PluginManifest(
            id: "com.example.bad",
            name: "Bad",
            version: "1.0.0",
            keywords: ["bad"],
            runtime: PluginRuntimeSpec(mode: .oneshot, command: ["../outside/run"])
        )
        #expect(throws: PluginManifestError.pathTraversal("../outside/run")) {
            _ = try PluginManifestLoader.validate(badCommand, in: dir, origin: .user)
        }

        let badIcon = PluginManifest(
            id: "com.example.badicon",
            name: "BadIcon",
            version: "1.0.0",
            keywords: ["bad"],
            icon: "../../secret.png",
            runtime: PluginRuntimeSpec(mode: .oneshot, command: ["bin/run"])
        )
        #expect(throws: PluginManifestError.pathTraversal("../../secret.png")) {
            _ = try PluginManifestLoader.validate(badIcon, in: dir, origin: .user)
        }
    }

    @Test func rejectsInvalidIDsAndEmptyKeywords() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(at: dir.appendingPathComponent("bin/run"))

        let badID = PluginManifest(
            id: "Invalid ID!",
            name: "Invalid",
            version: "1.0.0",
            keywords: ["ok"],
            runtime: PluginRuntimeSpec(mode: .oneshot, command: ["bin/run"])
        )
        #expect(throws: PluginManifestError.invalidPluginID("Invalid ID!")) {
            _ = try PluginManifestLoader.validate(badID, in: dir, origin: .user)
        }

        let emptyKeywords = PluginManifest(
            id: "com.example.nokey",
            name: "NoKey",
            version: "1.0.0",
            keywords: ["   ", ""],
            runtime: PluginRuntimeSpec(mode: .oneshot, command: ["bin/run"])
        )
        #expect(throws: PluginManifestError.emptyKeywords) {
            _ = try PluginManifestLoader.validate(emptyKeywords, in: dir, origin: .user)
        }
    }

    @Test func forbidsUserPluginFromUsingLegacyProviderIDOrHostHelpers() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helpersDir = dir.appendingPathComponent("helpers", isDirectory: true)
        try makeExecutable(at: dir.appendingPathComponent("bin/run"))
        try makeExecutable(at: helpersDir.appendingPathComponent("MyHelper"))

        let userWithLegacy = PluginManifest(
            id: "com.example.spoof",
            name: "Spoof",
            version: "1.0.0",
            keywords: ["kill"],
            legacyProviderID: "killProcess",
            runtime: PluginRuntimeSpec(mode: .oneshot, command: ["bin/run"])
        )
        #expect(throws: PluginManifestError.forbiddenForUserPlugin("legacyProviderID")) {
            _ = try PluginManifestLoader.validate(userWithLegacy, in: dir, origin: .user, helpersDirectory: helpersDir)
        }

        let userWithHelpers = PluginManifest(
            id: "com.example.helper",
            name: "Helper",
            version: "1.0.0",
            keywords: ["help"],
            runtime: PluginRuntimeSpec(mode: .daemon, command: ["$HOST_HELPERS/MyHelper"])
        )
        #expect(throws: PluginManifestError.forbiddenForUserPlugin("$HOST_HELPERS")) {
            _ = try PluginManifestLoader.validate(userWithHelpers, in: dir, origin: .user, helpersDirectory: helpersDir)
        }

        let bundledWithHelpers = PluginManifest(
            id: "com.donts.official",
            name: "Official",
            version: "1.0.0",
            keywords: ["off"],
            priority: 180,
            legacyProviderID: "killProcess",
            runtime: PluginRuntimeSpec(mode: .daemon, command: ["$HOST_HELPERS/MyHelper"])
        )
        let resolved = try PluginManifestLoader.validate(
            bundledWithHelpers,
            in: dir,
            origin: .bundled,
            helpersDirectory: helpersDir
        )
        #expect(resolved.priority == 180)
        #expect(resolved.legacyProviderID == "killProcess")
        #expect(resolved.executableURL.lastPathComponent == "MyHelper")
    }

    @Test func validatesMinHostVersionAndExtendedPermissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(at: dir.appendingPathComponent("bin/run"))

        #expect(PluginPermission.openTerminal.rawValue == "openTerminal")
        #expect(PluginPermission.openTerminal.displayName == "在首选终端打开")
        #expect(PluginPermission.openApplication.rawValue == "openApplication")
        #expect(PluginPermission.openApplication.displayName == "启动本机应用")
        #expect(PluginPermission.openAI.rawValue == "openAI")
        #expect(PluginPermission.openAI.displayName == "调用宿主 AI 对话窗口")

        #expect(PluginVersion.isNewer("1.1.0", than: "1.0.9"))
        #expect(PluginVersion.isNewer("1.0.0", than: "1.0.0-beta.2"))
        #expect(!PluginVersion.isNewer("1.0.0", than: "1.0.0"))
        #expect(PluginVersion.isSatisfied(minimum: "0.2.14", by: "0.2.14"))
        #expect(PluginVersion.isSatisfied(minimum: "0.2", by: "0.2.14"))
        #expect(!PluginVersion.isSatisfied(minimum: "0.3.0", by: "0.2.14"))

        let manifest = PluginManifest(
            id: "com.example.term",
            name: "Term",
            version: "1.0.0",
            minHostVersion: "0.2.14",
            keywords: ["tm"],
            runtime: PluginRuntimeSpec(mode: .oneshot, command: ["bin/run"]),
            permissions: [.openTerminal, .openApplication]
        )
        let ok = try PluginManifestLoader.validate(manifest, in: dir, origin: .user, hostVersion: "0.2.14")
        #expect(ok.permissions == [.openTerminal, .openApplication])
        #expect(ok.minHostVersion == "0.2.14")

        #expect(throws: PluginManifestError.incompatibleHostVersion(required: "0.2.14", current: "0.2.13")) {
            _ = try PluginManifestLoader.validate(manifest, in: dir, origin: .user, hostVersion: "0.2.13")
        }

        let invalidVersionManifest = PluginManifest(
            id: "com.example.badver",
            name: "BadVer",
            version: "1.0.0",
            minHostVersion: "not-a-version",
            keywords: ["bv"],
            runtime: PluginRuntimeSpec(mode: .oneshot, command: ["bin/run"])
        )
        #expect(throws: PluginManifestError.invalidMinHostVersion("not-a-version")) {
            _ = try PluginManifestLoader.validate(invalidVersionManifest, in: dir, origin: .user, hostVersion: "0.2.14")
        }
    }
}
