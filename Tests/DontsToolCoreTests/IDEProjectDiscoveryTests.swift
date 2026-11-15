import Foundation
import Testing
@testable import DontsToolCore

@Suite("IDEA project discovery")
struct IDEProjectDiscoveryTests {
    @Test func readsHomeMacrosSpacesCustomNamesAndMostRecentTimestamp() throws {
        let data = Data("""
        <application><component name="RecentProjectsManager"><option name="additionalInfo"><map>
        <entry key="$USER_HOME$/Dev Workbench/Old"><value><RecentProjectMetaInfo><option name="projectOpenTimestamp" value="100"/><option name="activationTimestamp" value="300"/><option name="customProjectName" value="Old display"/></RecentProjectMetaInfo></value></entry>
        <entry key="$USER_HOME$/Desktop/New"><value><RecentProjectMetaInfo><option name="projectOpenTimestamp" value="200"/></RecentProjectMetaInfo></value></entry>
        <entry key="ssh://host/project"><value><RecentProjectMetaInfo/></value></entry>
        <entry key="$UNKNOWN$/bad"><value><RecentProjectMetaInfo/></value></entry>
        <entry key="$USER_HOME$/Hidden"><value><RecentProjectMetaInfo hidden="true"/></value></entry>
        </map></option></component></application>
        """.utf8)
        let projects = try IDERecentProjectsParser.parse(data, homeDirectory: URL(fileURLWithPath: "/Users/test"))
        #expect(projects.map(\.url.path) == ["/Users/test/Dev Workbench/Old", "/Users/test/Desktop/New"])
        #expect(projects.map(\.name) == ["Old display", "New"])
        #expect(projects.first?.lastOpenedTimestamp == 300)
    }

    @Test func rejectsMalformedXMLExternalEntitiesAndOversizeDocuments() {
        for xml in ["<application><component>", "<!DOCTYPE x [<!ENTITY local SYSTEM 'file:///etc/passwd'>]><application>&local;</application>"] {
            #expect(throws: (any Error).self) { try IDERecentProjectsParser.parse(Data(xml.utf8), homeDirectory: URL(fileURLWithPath: "/Users/test")) }
        }
        #expect(throws: (any Error).self) { try IDERecentProjectsParser.parse(Data(repeating: 32, count: 4 * 1024 * 1024 + 1), homeDirectory: URL(fileURLWithPath: "/Users/test")) }
    }

    @Test func rejectsEncodedDoctypesBeforeXMLParserCanExpandEntities() {
        let xml = "<!DOCTYPE application [<!ENTITY value 'expanded'>]><application>&value;</application>"
        for encoding in [String.Encoding.utf16, .utf16BigEndian, .utf16LittleEndian] {
            #expect(throws: (any Error).self) { try IDERecentProjectsParser.parse(xml.data(using: encoding)!, homeDirectory: URL(fileURLWithPath: "/Users/test")) }
        }
    }

    @Test func ignoresUnrelatedEntriesAndDeduplicatesProjectPaths() throws {
        let xml = """
        <application><component name="Unrelated"><option name="additionalInfo"><map><entry key="/tmp/wrong"/></map></option></component>
        <component name="RecentProjectsManager"><option name="additionalInfo"><map>
        <entry key="/tmp/project"><value><RecentProjectMetaInfo><option name="activationTimestamp" value="3"/></RecentProjectMetaInfo></value></entry>
        <entry key="/tmp/project/../project"><value><RecentProjectMetaInfo><option name="activationTimestamp" value="5"/></RecentProjectMetaInfo></value></entry>
        </map></option></component></application>
        """
        let items = try IDERecentProjectsParser.parse(Data(xml.utf8), homeDirectory: URL(fileURLWithPath: "/Users/test"))
        #expect(items.count == 1)
        #expect(items.first?.lastOpenedTimestamp == 5)
    }

    @Test func usesInstalledVersionFiltersMissingDirectoriesAndUpdatesCache() async throws {
        let fixture = try IDEProjectFixture()
        defer { fixture.remove() }
        let old = try fixture.project("Old")
        let recent = try fixture.project("Recent Project")
        let missing = fixture.root.appendingPathComponent("Missing")
        try fixture.history(version: "2026.2", paths: [(old.path, 999)])
        try fixture.history(version: "2026.3", paths: [(recent.path, 1), (missing.path, 2)])
        let discovery = IDEProjectDiscovery(homeDirectory: fixture.root, jetBrainsDirectory: fixture.config, applicationRoots: [])
        let apps = [IDEApplicationCandidate(url: fixture.app, bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA")]
        let first = await discovery.discover(applications: apps, manualPath: nil)
        #expect(first.projects.map(\.url.path) == [recent.path])
        #expect(first.application?.version == "2026.3")
        let cached = await discovery.discover(applications: apps, manualPath: nil)
        #expect(cached.projects == first.projects)
        try fixture.history(version: "2026.3", paths: [(old.path, 4)])
        let updated = await discovery.discover(applications: apps, manualPath: nil)
        #expect(updated.projects.map(\.url.path) == [old.path])
        try FileManager.default.removeItem(at: old)
        let deleted = await discovery.discover(applications: apps, manualPath: nil)
        #expect(deleted.projects.isEmpty)
    }

    @Test func unchangedFingerprintUsesCachedXMLUntilTheFileChanges() async throws {
        let fixture = try IDEProjectFixture()
        defer { fixture.remove() }
        let project = try fixture.project("Cached")
        try fixture.history(version: "2026.3", paths: [(project.path, 4)])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
                                             ofItemAtPath: fixture.historyURL("2026.3").path)
        let discovery = IDEProjectDiscovery(homeDirectory: fixture.root, jetBrainsDirectory: fixture.config, applicationRoots: [])
        let apps = [IDEApplicationCandidate(url: fixture.app, bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA")]
        _ = await discovery.discover(applications: apps, manualPath: nil)
        let url = fixture.historyURL("2026.3")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("!".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: url.path)
        let cached = await discovery.discover(applications: apps, manualPath: nil)
        #expect(cached.projects.map(\.url.path) == [project.path])
        #expect(cached.notice == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: url.path)
        let reread = await discovery.discover(applications: apps, manualPath: nil)
        #expect(reread.notice != nil)
    }

    @Test func malformedReplacementKeepsLastCompleteSnapshotAndManualPathIsValidated() async throws {
        let fixture = try IDEProjectFixture()
        defer { fixture.remove() }
        let project = try fixture.project("Project with spaces")
        try fixture.history(version: "2026.3", paths: [(project.path, 4)])
        let discovery = IDEProjectDiscovery(homeDirectory: fixture.root, jetBrainsDirectory: fixture.config, applicationRoots: [])
        let apps = [IDEApplicationCandidate(url: fixture.app, bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA")]
        _ = await discovery.discover(applications: apps, manualPath: nil)
        try Data("<application>".utf8).write(to: fixture.historyURL("2026.3"), options: .atomic)
        let damaged = await discovery.discover(applications: apps, manualPath: nil)
        #expect(damaged.projects.map(\.url.path) == [project.path])
        #expect(damaged.notice != nil)
        let manual = await discovery.discover(applications: apps, manualPath: project.path)
        #expect(manual.projects.map(\.url.path) == [project.path])
        for path in ["ssh://host/project", "//server/project", fixture.root.appendingPathComponent("absent").path] {
            let result = await discovery.discover(applications: apps, manualPath: path)
            #expect(result.projects.isEmpty)
            #expect(result.notice != nil)
        }
    }

    @Test func missingIDEAndMissingMatchingVersionHaveUsefulNotices() async throws {
        let fixture = try IDEProjectFixture()
        defer { fixture.remove() }
        let discovery = IDEProjectDiscovery(homeDirectory: fixture.root, jetBrainsDirectory: fixture.config, applicationRoots: [])
        let absent = await discovery.discover(applications: [], manualPath: nil)
        #expect(absent.application == nil)
        #expect(absent.notice != nil)
        let old = try fixture.project("Old")
        try fixture.history(version: "2026.2", paths: [(old.path, 8)])
        let result = await discovery.discover(applications: [IDEApplicationCandidate(url: fixture.app, bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA")], manualPath: nil)
        #expect(result.projects.isEmpty)
        #expect(result.notice != nil)
    }
}

struct IDEProjectFixture {
    let root: URL
    let app: URL
    let config: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("idea-tests-\(UUID().uuidString)")
        app = root.appendingPathComponent("IntelliJ IDEA.app")
        config = root.appendingPathComponent("JetBrains")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": "com.jetbrains.intellij", "CFBundleShortVersionString": "2026.3", "CFBundleExecutable": "idea"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: app.appendingPathComponent("Contents/MacOS/idea"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func project(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func historyURL(_ version: String) -> URL { config.appendingPathComponent("IntelliJIdea\(version)/options/recentProjects.xml") }
    func history(version: String, paths: [(String, Int)]) throws {
        let url = historyURL(version)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entries = paths.map { "<entry key=\"\($0.0)\"><value><RecentProjectMetaInfo><option name=\"activationTimestamp\" value=\"\($0.1)\"/></RecentProjectMetaInfo></value></entry>" }.joined()
        let xml = "<application><component name=\"RecentProjectsManager\"><option name=\"additionalInfo\"><map>\(entries)</map></option></component></application>"
        try Data(xml.utf8).write(to: url, options: .atomic)
    }
}
