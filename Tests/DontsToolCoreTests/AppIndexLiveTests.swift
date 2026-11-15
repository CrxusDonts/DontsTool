import Combine
import Foundation
import Testing
@testable import DontsToolCore

@Suite("AppIndex live directory changes", .serialized)
@MainActor
struct AppIndexLiveTests {
    @Test func installingAnAppUpdatesTheRunningIndex() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = AppIndex(scanner: AppScanner(roots: [root]))
        defer { index.stopMonitoring() }
        await index.scan()
        #expect(index.apps.isEmpty)

        let app = try installApp(in: root, name: "Fresh.app", displayName: "Fresh App")
        try await until { index.apps.contains { $0.url == app.standardizedFileURL } }
        #expect(index.apps.map(\.displayName) == ["Fresh App"])
    }

    @Test func removingAnAppRemovesItsSearchResult() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try installApp(in: root, name: "Gone.app", displayName: "Gone App")
        let index = AppIndex(scanner: AppScanner(roots: [root]))
        defer { index.stopMonitoring() }
        await index.scan()
        #expect(index.apps.count == 1)

        try FileManager.default.removeItem(at: app)
        try await until { index.apps.isEmpty }
    }

    @Test func finishingAnInProgressInstallIsDetected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = AppIndex(scanner: AppScanner(roots: [root]))
        defer { index.stopMonitoring() }
        await index.scan()
        var observedScans = 0
        let observation = index.$isScanning.sink { if $0 { observedScans += 1 } }
        defer { observation.cancel() }
        let app = root.appendingPathComponent("Gradual.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try await until { observedScans > 0 && !index.isScanning }
        #expect(index.apps.isEmpty)
        // The directory can appear before Contents/Info.plist has been copied.
        _ = try installApp(in: root, name: "Gradual.app", displayName: "Gradual App")
        try await until { index.apps.contains { $0.displayName == "Gradual App" } }
    }

    @Test func updatingAnAppRefreshesItsMetadata() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installApp(in: root, name: "Updated.app", displayName: "Before")
        let index = AppIndex(scanner: AppScanner(roots: [root]))
        defer { index.stopMonitoring() }
        await index.scan()
        _ = try installApp(in: root, name: "Updated.app", displayName: "After")
        try await until { index.apps.map(\.displayName) == ["After"] }
    }

    @Test func creatingAPreviouslyMissingApplicationDirectoryIsDetected() async throws {
        let parent = try makeRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Applications", isDirectory: true)
        let index = AppIndex(scanner: AppScanner(roots: [root]))
        defer { index.stopMonitoring() }
        await index.scan()
        _ = try installApp(in: root, name: "New.app", displayName: "New App")
        try await until { index.apps.map(\.displayName) == ["New App"] }
    }

    @Test func installingInsideAnApplicationGroupIsDetected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appendingPathComponent("Developer Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let index = AppIndex(scanner: AppScanner(roots: [root]))
        defer { index.stopMonitoring() }
        await index.scan()
        _ = try installApp(in: group, name: "Nested.app", displayName: "Nested App")
        try await until { index.apps.map(\.displayName) == ["Nested App"] }
    }

    @Test func stoppingMonitoringKeepsSnapshotUntilNextExplicitScan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = AppIndex(scanner: AppScanner(roots: [root]))
        defer { index.stopMonitoring() }
        await index.scan()
        index.stopMonitoring()
        _ = try installApp(in: root, name: "Paused.app", displayName: "Paused App")
        // This is a bounded negative observation: no callback may refresh after stop.
        try await Task.sleep(for: .seconds(1))
        #expect(index.apps.isEmpty)
        await index.scan()
        #expect(index.apps.map(\.displayName) == ["Paused App"])
    }

    private func makeRoot() throws -> URL {
        // macOS omits the system temporary tree from FSEvents. Use an ignored
        // build fixture so this exercises real delivered filesystem events.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/app-index-fixtures", isDirectory: true)
            .appendingPathComponent("DontsToolLiveIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func installApp(in root: URL, name: String, displayName: String) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleName": displayName,
            "CFBundleIdentifier": "com.donts.test.\(name)"
        ], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        return app
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw IndexTestError.changeNotIndexed }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

private enum IndexTestError: Error { case changeNotIndexed }
