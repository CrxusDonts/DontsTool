import Foundation
import Testing
@testable import DontsToolCore

@Suite("PluginCatalog")
struct PluginCatalogTests {
    @Test func decodesAndValidatesSingleAndMultiPluginCatalogs() throws {
        let json = """
        {
          "schemaVersion": 1,
          "sourceName": "DontsTool 官方插件集",
          "plugins": [
            {
              "id": "com.donts.kill-process",
              "name": "结束进程",
              "summary": "按名称、PID 或端口列出并结束进程",
              "version": "1.1.0",
              "minHostVersion": "0.3.0",
              "downloadURL": "https://github.com/donts/dontstool-plugins/releases/download/kill-process-v1.1.0/kill-process.dontsplugin.zip",
              "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
              "official": true
            },
            {
              "id": "com.donts.idea-projects",
              "name": "IDEA 项目",
              "version": "1.0.0",
              "subpath": "plugins/idea-projects",
              "official": true
            }
          ]
        }
        """

        let catalog = try PluginCatalogValidator.decodeAndValidate(Data(json.utf8))
        #expect(catalog.sourceName == "DontsTool 官方插件集")
        #expect(catalog.plugins.count == 2)
        #expect(catalog.plugins[0].id == "com.donts.kill-process")
        #expect(catalog.plugins[1].subpath == "plugins/idea-projects")
    }

    @Test func rejectsDuplicateIDsNonHTTPSURLsAndInvalidSHA256() {
        let duplicate = PluginCatalog(
            sourceName: "Repo",
            plugins: [
                PluginCatalogEntry(id: "com.example.a", name: "A1", version: "1.0.0"),
                PluginCatalogEntry(id: "com.example.a", name: "A2", version: "1.1.0")
            ]
        )
        #expect(throws: PluginCatalogError.duplicatePluginID("com.example.a")) {
            try PluginCatalogValidator.validate(duplicate)
        }

        let insecureURL = PluginCatalog(
            sourceName: "Repo",
            plugins: [
                PluginCatalogEntry(
                    id: "com.example.http",
                    name: "HTTP",
                    version: "1.0.0",
                    downloadURL: "http://example.com/plugin.zip"
                )
            ]
        )
        #expect(throws: PluginCatalogError.invalidDownloadURL("http://example.com/plugin.zip", pluginID: "com.example.http")) {
            try PluginCatalogValidator.validate(insecureURL)
        }

        let badHash = PluginCatalog(
            sourceName: "Repo",
            plugins: [
                PluginCatalogEntry(
                    id: "com.example.badhash",
                    name: "BadHash",
                    version: "1.0.0",
                    sha256: "not-a-sha256"
                )
            ]
        )
        #expect(throws: PluginCatalogError.invalidSHA256("not-a-sha256", pluginID: "com.example.badhash")) {
            try PluginCatalogValidator.validate(badHash)
        }

        let badSubpath = PluginCatalog(
            sourceName: "Repo",
            plugins: [
                PluginCatalogEntry(
                    id: "com.example.sub",
                    name: "Sub",
                    version: "1.0.0",
                    subpath: "../escape"
                )
            ]
        )
        #expect(throws: PluginCatalogError.invalidSubpath("../escape", pluginID: "com.example.sub")) {
            try PluginCatalogValidator.validate(badSubpath)
        }
    }

    @Test func detectsCrossSourceConflict() {
        let existing = PluginInstallMetadata(
            pluginID: "com.example.jira",
            version: "1.0.0",
            sourceRepo: "alice/jira-plugin"
        )
        #expect(!PluginCatalogValidator.detectSourceConflict(
            incomingPluginID: "com.example.jira",
            incomingSourceRepo: "ALICE/jira-plugin",
            existingMetadata: existing
        ))
        #expect(PluginCatalogValidator.detectSourceConflict(
            incomingPluginID: "com.example.jira",
            incomingSourceRepo: "mallory/evil-jira",
            existingMetadata: existing
        ))
    }
}
