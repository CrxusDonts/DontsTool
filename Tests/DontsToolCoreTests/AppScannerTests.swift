import Foundation
import Testing
@testable import DontsToolCore

@Suite("AppScanner")
struct AppScannerTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DontsToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(at root: URL, name: String, plist: [String: Any]) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func writeLocalizedInfo(at app: URL, localization: String, data: Data) throws {
        let directory = app.appendingPathComponent("Contents/Resources/\(localization).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("InfoPlist.strings"), options: .atomic)
    }

    @Test(arguments: ["utf8", "utf16", "binary"])
    func readsPreferredChineseLocalizedName(format: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, name: "WeChat.app", plist: ["CFBundleDisplayName": "WeChat", "CFBundleName": "WeChat"])
        let info = ["CFBundleDisplayName": "微信", "CFBundleName": "微信"]
        let data: Data
        switch format {
        case "binary":
            data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        case "utf16":
            data = try #require("\"CFBundleDisplayName\" = \"微信\";\n\"CFBundleName\" = \"微信\";".data(using: .utf16))
        default:
            data = Data("\"CFBundleDisplayName\" = \"微信\";\n\"CFBundleName\" = \"微信\";".utf8)
        }
        try writeLocalizedInfo(at: app, localization: "zh-Hans", data: data)
        try writeLocalizedInfo(at: app, localization: "en", data: Data("\"CFBundleDisplayName\" = \"WeChat\";".utf8))

        let result = AppScanner(roots: [root], preferredLanguages: ["zh-Hans-CN", "en"]).scan()
        #expect(result.entries.map(\.displayName) == ["微信"])
    }

    @Test func englishPreferenceKeepsEnglishApplicationName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, name: "WeChat.app", plist: ["CFBundleDisplayName": "WeChat"])
        try writeLocalizedInfo(at: app, localization: "zh-Hans", data: Data("\"CFBundleDisplayName\" = \"微信\";".utf8))
        try writeLocalizedInfo(at: app, localization: "en", data: Data("\"CFBundleDisplayName\" = \"WeChat\";".utf8))

        let result = AppScanner(roots: [root], preferredLanguages: ["en", "zh-Hans"]).scan()
        #expect(result.entries.map(\.displayName) == ["WeChat"])
    }

    @Test func localizedNameChangesAtTheSameApplicationPathAreFresh() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, name: "WeChat.app", plist: ["CFBundleName": "WeChat"])
        try writeLocalizedInfo(at: app, localization: "zh-Hans", data: Data("\"CFBundleDisplayName\" = \"微信\";".utf8))
        let scanner = AppScanner(roots: [root], preferredLanguages: ["zh-Hans"])
        #expect(scanner.scan().entries.map(\.displayName) == ["微信"])

        try writeLocalizedInfo(at: app, localization: "zh-Hans", data: Data("\"CFBundleDisplayName\" = \"微信新版\";".utf8))

        #expect(scanner.scan().entries.map(\.displayName) == ["微信新版"])
    }

    @Test func unreadableLocalizedNameFallsBackToRawMetadata() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, name: "WeChat.app", plist: ["CFBundleDisplayName": "WeChat"])
        try writeLocalizedInfo(at: app, localization: "zh-Hans", data: Data([0x00, 0xff, 0x01]))

        let result = AppScanner(roots: [root], preferredLanguages: ["zh-Hans"]).scan()
        #expect(result.entries.map(\.displayName) == ["WeChat"])
    }

    @Test func readsFreshNamesFromInfoPlistLocalizationTable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, name: "Terminal.app", plist: ["CFBundleDisplayName": "Terminal"])
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let table = resources.appendingPathComponent("InfoPlist.loctable")
        let localizedInfo = [
            "zh_CN": ["CFBundleDisplayName": "终端"],
            "en": ["CFBundleDisplayName": "Terminal"]
        ]
        try PropertyListSerialization.data(fromPropertyList: localizedInfo, format: .binary, options: 0).write(to: table)
        let scanner = AppScanner(roots: [root], preferredLanguages: ["zh-Hans-CN", "en"])
        #expect(scanner.scan().entries.map(\.displayName) == ["终端"])
        #expect(AppScanner(roots: [root], preferredLanguages: ["en"]).scan().entries.map(\.displayName) == ["Terminal"])

        let updatedInfo = ["zh_CN": ["CFBundleDisplayName": "终端新版"]]
        try PropertyListSerialization.data(fromPropertyList: updatedInfo, format: .binary, options: 0).write(to: table, options: .atomic)

        #expect(scanner.scan().entries.map(\.displayName) == ["终端新版"])
    }

    @Test func readsDisplayNameThenBundleNameThenFileName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApp(at: root, name: "A.app", plist: ["CFBundleDisplayName": "Alpha", "CFBundleName": "AlphaBundle"])
        _ = try makeApp(at: root, name: "B.app", plist: ["CFBundleName": "Beta"])
        _ = try makeApp(at: root, name: "Gamma.app", plist: [:])

        let result = AppScanner(roots: [root]).scan()
        let names = Set(result.entries.map(\.displayName))
        #expect(names.contains("Alpha"))
        #expect(names.contains("Beta"))
        #expect(names.contains("Gamma"))
    }

    @Test func scansOneLevelOfSubdirectories() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        _ = try makeApp(at: group, name: "Terminal.app", plist: ["CFBundleName": "Terminal"])

        let result = AppScanner(roots: [root]).scan()
        #expect(result.entries.map(\.displayName).contains("Terminal"))
    }

    @Test func skipsNestedAppsInsidePackages() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = try makeApp(at: root, name: "Outer.app", plist: ["CFBundleName": "Outer"])
        let helpers = outer.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        _ = try makeApp(at: helpers, name: "Helper.app", plist: ["CFBundleName": "Helper"])

        let result = AppScanner(roots: [root]).scan()
        #expect(result.entries.map(\.displayName) == ["Outer"])
    }

    @Test func skipsBackgroundOnlyApps() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApp(at: root, name: "Visible.app", plist: ["CFBundleName": "Visible"])
        _ = try makeApp(at: root, name: "Hidden.app", plist: ["CFBundleName": "Hidden", "LSBackgroundOnly": true])

        let result = AppScanner(roots: [root]).scan()
        #expect(result.entries.map(\.displayName) == ["Visible"])
    }

    @Test func skipsHiddenDirectories() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".HiddenGroup", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        _ = try makeApp(at: hidden, name: "Secret.app", plist: ["CFBundleName": "Secret"])

        let result = AppScanner(roots: [root]).scan()
        #expect(result.entries.isEmpty)
    }

    @Test func readsUpdatedMetadataAtTheSameApplicationPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApp(at: root, name: "Updated.app", plist: ["CFBundleName": "Before"])
        let scanner = AppScanner(roots: [root])
        #expect(scanner.scan().entries.map(\.displayName) == ["Before"])
        _ = try makeApp(at: root, name: "Updated.app", plist: ["CFBundleName": "After"])
        #expect(scanner.scan().entries.map(\.displayName) == ["After"])
    }
}
