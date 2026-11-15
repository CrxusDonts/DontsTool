import DontsToolCore
import Foundation
import Testing

@Suite("Website shortcut form drafts")
@MainActor
struct WebsiteShortcutFormTests {
    @Test func caseOnlyEnvironmentEditsKeepTheExistingPageOverrideField() {
        let keys = ShortcutPageDraft.environmentKeys([" PROD ", "prod", "Test", ""])
        #expect(keys == ["prod", "test"])
        let overrides = ["prod": "https://avatar.company.example/admin"]
        #expect(overrides.keys.filter { !keys.contains($0) }.isEmpty)
        #expect(keys.first.flatMap { overrides[$0] } == "https://avatar.company.example/admin")
    }

    private func legacyConfiguration() -> WebsiteShortcutConfiguration {
        .init(version: 1, groups: [.init(keyword: "ops", name: "业务系统", items: [
            .init(key: "订单", name: "订单管理", url: "https://orders.company.example", aliases: ["orders"]),
        ])])
    }

    @Test func savingEnvironmentsUpgradesLegacyConfigurationWithoutMutatingIt() throws {
        let original = legacyConfiguration()
        var draft = ShortcutFormDraft.item(group: 0, index: 0, value: original.groups[0].items[0])
        draft.addressMode = .environments
        draft.environments[0].url = "https://orders.test.company.example"
        draft.environments[0].aliases = " 测试环境 \n测试站"
        draft.environments[1].url = "https://orders.company.example"
        let saved = try draft.proposal(in: original).validated()
        #expect(saved.version == 2)
        #expect(saved.groups[0].items[0].url.isEmpty)
        #expect(saved.groups[0].items[0].environments.map(\.key) == ["test", "prod"])
        #expect(saved.groups[0].items[0].environments[0].aliases == ["测试环境", "测试站"])
        #expect(saved.itemCount == 1)
        #expect(saved.addressCount == 2)
        #expect(original == legacyConfiguration())
    }

    @Test func switchingModesRetainsBothDraftsAndOnlySavesTheActiveOne() throws {
        let original = legacyConfiguration()
        var draft = ShortcutFormDraft.item(group: 0, index: 0, value: original.groups[0].items[0])
        draft.url = "https://orders.company.example/path?q=1#section"
        draft.addressMode = .environments
        draft.environments[0].url = "https://orders.test.company.example"
        draft.environments[1].url = "https://orders.company.example"
        let environmentDraft = draft.environments
        draft.addressMode = .single
        let single = try draft.proposal(in: original).validated()
        #expect(single.version == 1)
        #expect(single.groups[0].items[0].url == draft.url)
        #expect(single.groups[0].items[0].environments.isEmpty)
        draft.addressMode = .environments
        #expect(draft.environments == environmentDraft)
        #expect(draft.url == "https://orders.company.example/path?q=1#section")
        #expect(try draft.proposal(in: original).validated().groups[0].items[0].url.isEmpty)
    }

    @Test func everyEnvironmentEditMakesTheDraftDirtyIncludingHiddenChanges() {
        let original = ShortcutFormDraft.item(group: 0)
        let fields: [WritableKeyPath<ShortcutEnvironmentDraft, String>] = [\.key, \.name, \.url, \.aliases]
        for field in fields {
            var draft = original
            draft.environments[0][keyPath: field] += "changed"
            #expect(draft != original)
        }
        var draft = original
        draft.environments.append(.init(key: "staging"))
        #expect(draft != original)
        draft = original
        draft.environments.removeLast()
        #expect(draft != original)
        draft = original
        draft.addressMode = .environments
        #expect(draft != original)
        draft.addressMode = .single
        #expect(draft == original)
    }

    @Test func removingAllEnvironmentsCannotSaveAnEmptyAddressSystem() {
        let original = legacyConfiguration()
        var draft = ShortcutFormDraft.item(group: 0, index: 0, value: original.groups[0].items[0])
        draft.addressMode = .environments
        draft.environments.removeAll()
        #expect(throws: (any Error).self) { try draft.proposal(in: original).validated() }
    }

    @Test func addingPagesUpgradesLegacyConfigurationAndKeepsRootRelativePath() throws {
        let original = legacyConfiguration()
        var draft = ShortcutFormDraft.item(group: 0, index: 0, value: original.groups[0].items[0])
        draft.pages = [.init(key: "management", name: "管理后台", path: "/management?tab=users#active", aliases: " managment \n管理")]
        let saved = try draft.proposal(in: original).validated()
        #expect(saved.version == 3)
        #expect(saved.pageCount == 1)
        #expect(saved.addressCount == 2)
        #expect(saved.groups[0].items[0].pages[0].path == "/management?tab=users#active")
        #expect(saved.groups[0].items[0].pages[0].aliases == ["managment", "管理"])
        #expect(original == legacyConfiguration())
    }

    @Test func editingEveryPageFieldMakesDraftDirtyAcrossModeChanges() {
        var original = ShortcutFormDraft.item(group: 0)
        original.pages = [.init(key: "management", name: "管理后台", path: "/management")]
        let fields: [WritableKeyPath<ShortcutPageDraft, String>] = [\.key, \.name, \.path, \.aliases]
        for field in fields {
            var draft = original
            draft.pages[0][keyPath: field] += "changed"
            draft.addressMode = .environments
            draft.addressMode = .single
            #expect(draft != original)
        }
        var draft = original
        draft.pages[0].urls["prod"] = "https://admin.company.example"
        #expect(draft != original)
        draft = original
        draft.pages.append(.init(key: "reports", name: "报表", path: "/reports"))
        #expect(draft != original)
        draft = original
        draft.pages.removeAll()
        #expect(draft != original)
    }

    @Test func pageAndEnvironmentDraftsRemainAvailableWhenCancellingModeChange() throws {
        let original = try WebsiteShortcutConfiguration.decode(WebsiteShortcutsSettingsView.exampleJSON)
        let initial = ShortcutFormDraft.item(group: 0, index: 0, value: original.groups[0].items[0])
        var draft = initial
        draft.pages[0].path = "/management/settings"
        draft.addressMode = .single
        draft.url = "https://avatar.company.example"
        #expect(draft.pages[0].path == "/management/settings")
        #expect(draft.environments == initial.environments)
        #expect(draft != initial)
        draft.addressMode = .environments
        #expect(draft.pages[0].path == "/management/settings")
        #expect(draft.pages[1].urls == initial.pages[1].urls)
        #expect(original.groups[0].items[0].pages[0].path == "/management")
        #expect(try draft.proposal(in: original).validated().version == 3)
    }

    @Test func environmentRemovalOrRenamePreservesOverridesAndFailsValidation() throws {
        let original = try WebsiteShortcutConfiguration.decode(WebsiteShortcutsSettingsView.exampleJSON)
        let initial = ShortcutFormDraft.item(group: 0, index: 0, value: original.groups[0].items[0])
        var draft = initial
        draft.environments[1].key = "live"
        #expect(draft.pages[1].urls["prod"] == "https://reports.company.example/dashboard")
        #expect(throws: (any Error).self) { try draft.proposal(in: original).validated() }
        draft = initial
        draft.environments.removeLast()
        #expect(draft.proposal(in: original).groups[0].items[0].pages[1].urls == initial.pages[1].urls)
        #expect(throws: (any Error).self) { try draft.proposal(in: original).validated() }
        draft.pages[1].urls.removeValue(forKey: "prod")
        #expect(try draft.proposal(in: original).validated().groups[0].items[0].pages[1].urls.isEmpty)
    }

    @Test func singleModeCannotSilentlyDropEnvironmentPageOverrides() throws {
        let original = try WebsiteShortcutConfiguration.decode(WebsiteShortcutsSettingsView.exampleJSON)
        var draft = ShortcutFormDraft.item(group: 0, index: 0, value: original.groups[0].items[0])
        draft.addressMode = .single
        draft.url = "https://avatar.company.example"
        let proposal = draft.proposal(in: original)
        #expect(proposal.groups[0].items[0].pages[1].urls["prod"] == "https://reports.company.example/dashboard")
        #expect(throws: (any Error).self) { try proposal.validated() }
        draft.pages[1].urls.removeValue(forKey: "prod")
        #expect(try draft.proposal(in: original).validated().groups[0].items[0].environments.isEmpty)
    }

    @Test func editingLegacySystemsWithoutPagesKeepsTheirSchemaVersion() throws {
        for version in [1, 2] {
            var original = legacyConfiguration()
            original.version = version
            var draft = ShortcutFormDraft.item(group: 0, index: 0, value: original.groups[0].items[0])
            #expect(try draft.proposal(in: original).validated() == original)
            draft.name = "订单系统"
            let saved = try draft.proposal(in: original).validated()
            #expect(saved.version == version)
            #expect(saved.groups[0].items[0].pages.isEmpty)
        }
    }

    @Test func savingEnvironmentsInVersionThreeDoesNotDowngradeOtherPages() throws {
        var original = try WebsiteShortcutConfiguration.decode(WebsiteShortcutsSettingsView.exampleJSON)
        original.groups[0].items.append(.init(key: "other", name: "其他", url: "https://other.company.example"))
        var draft = ShortcutFormDraft.item(group: 0, index: 1, value: original.groups[0].items[1])
        draft.addressMode = .environments
        draft.environments[0].url = "https://other.test.company.example"
        draft.environments[1].url = "https://other.company.example"
        #expect(try draft.proposal(in: original).validated().version == 3)
    }

    @Test func settingsExampleShowsAvatarPagesAliasesAndSpecialEnvironmentURL() throws {
        let example = try WebsiteShortcutConfiguration.decode(WebsiteShortcutsSettingsView.exampleJSON)
        #expect(example.version == 3)
        #expect(example.itemCount == 1)
        #expect(example.pageCount == 2)
        #expect(example.addressCount == 6)
        #expect(example.groups[0].items[0].key == "avatar")
        #expect(example.groups[0].items[0].environments.map(\.key) == ["test", "prod"])
        #expect(example.groups[0].items[0].pages[0].aliases == ["managment", "管理"])
        #expect(example.groups[0].items[0].pages[1].urls == ["prod": "https://reports.company.example/dashboard"])
    }
}
