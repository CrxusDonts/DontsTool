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
}
