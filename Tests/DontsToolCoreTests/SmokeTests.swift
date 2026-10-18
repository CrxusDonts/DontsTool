import Testing
@testable import DontsToolCore

@Suite("Core 模块")
struct SmokeTests {
    @Test func appInfoIsAvailable() {
        #expect(AppInfo.displayName == "DontsTool")
        #expect(!AppInfo.version.isEmpty)
    }
}
