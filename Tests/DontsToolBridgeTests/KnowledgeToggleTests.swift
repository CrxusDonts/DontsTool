import DontsToolCore
import Foundation
import Testing

@Suite("知识库开关") @MainActor
struct KnowledgeToggleTests {
    @Test func disabledSearchDoesNotValidateOriginOrStartClient() async {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.setProviderEnabled(ProviderID.knowledge.rawValue, to: false)
        let manager = KnowledgeWindowManager(settings: settings)
        defer { manager.shutdown() }
        do {
            _ = try await manager.searchKnowledge("query")
            Issue.record("关闭后不应执行知识库搜索")
        } catch {
            #expect(error.localizedDescription == "知识库功能已关闭")
        }
    }
    @Test func disablingAndReenablingInvalidatesDebouncedSearch() async {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let manager = KnowledgeWindowManager(settings: settings)
        defer { manager.shutdown() }
        let search = Task { try await manager.searchKnowledge("query") }
        try? await Task.sleep(for: .milliseconds(30))
        settings.setProviderEnabled(ProviderID.knowledge.rawValue, to: false)
        settings.setProviderEnabled(ProviderID.knowledge.rawValue, to: true)
        do {
            _ = try await search.value
            Issue.record("关闭前的搜索不能在重新开启后继续执行")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
