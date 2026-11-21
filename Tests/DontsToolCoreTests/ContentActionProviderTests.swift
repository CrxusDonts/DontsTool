import Foundation
import Testing
@testable import DontsToolCore

@Suite("主动粘贴内容动作")
@MainActor
struct ContentActionProviderTests {
    private func makeProvider() -> (ContentActionProvider, SettingsStore, MockToolOpener, MockURLOpener, MockFeedback) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let tools = MockToolOpener()
        let urls = MockURLOpener()
        let feedback = MockFeedback()
        return (ContentActionProvider(settings: settings, toolOpener: tools, urlOpener: urls, feedback: feedback), settings, tools, urls, feedback)
    }

    @Test func descriptorRecognizesContainersButNotJSONScalarsOrUnsafeURLs() {
        #expect(ContentDescriptor(text: " \n{\"name\":\"测试\"}\n")?.kind == .json)
        #expect(ContentDescriptor(text: "[1, true, null]")?.kind == .json)
        #expect(ContentDescriptor(text: "{\"large\":1e400}")?.kind == .json)
        #expect(ContentDescriptor(text: "https://example.com/a?q=1")?.kind == .url)
        for text in ["42", "true", "\"hello\"", "{bad}", "javascript:alert(1)", "file:///tmp/test", "https://example.com hello"] {
            #expect(ContentDescriptor(text: text)?.kind == .text)
        }
        #expect(ContentDescriptor(text: "  \n\t") == nil)
    }

    @Test func descriptorBoundsPreviewAndRejectsInputBeyondEditorLimit() {
        let descriptor = ContentDescriptor(text: String(repeating: "a", count: 1000))
        #expect(descriptor?.displayTitle == "文本内容")
        #expect((descriptor?.summary.count ?? 0) < 120)
        #expect(ContentDescriptor(text: String(repeating: "a", count: ToolOperations.textByteLimit + 1)) == nil)
    }

    @Test func JSONOffersOnlyEditorAndOpensWithFormattedInput() async throws {
        let (provider, _, tools, urls, _) = makeProvider()
        let input = " \n{\"a\":[9007199254740993,true]} \n"
        let items = provider.items(for: input)
        #expect(items.map(\.keyword) == ["json"])
        #expect(tools.requests.isEmpty)
        #expect(urls.opened.isEmpty)
        let item = try #require(items.first)
        #expect(item.primaryAction?.presentation == .openWindow)
        try await item.primaryAction?.run()
        #expect(tools.requests == [ToolOpenRequest(kind: .json, mode: "format", input: input)])
        let request = try #require(tools.requests.first)
        let document = ToolDocumentStore().create(request)
        #expect(document.session.input == "{\n  \"a\": [\n    9007199254740993,\n    true\n  ]\n}")
    }

    @Test func URLProvidesBrowserAndBothCodecModesOnly() async throws {
        let (provider, _, tools, urls, _) = makeProvider()
        let input = " \nhttps://example.com/a%20b?q=%E4%B8%AD \n"
        let items = provider.items(for: input)
        #expect(items.count == 3)
        #expect(items.map(\.keyword) == [nil, "url", "urld"])
        #expect(urls.opened.isEmpty)
        try await items[0].primaryAction?.run()
        #expect(urls.opened == [URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines))!])
        try await items[1].primaryAction?.run()
        try await items[2].primaryAction?.run()
        #expect(tools.requests == [
            ToolOpenRequest(kind: .url, mode: "encode", input: input),
            ToolOpenRequest(kind: .url, mode: "decode", input: input)
        ])
    }

    @Test func textOffersCodecAndTranslationWithoutRunningThem() async throws {
        let (provider, _, tools, urls, _) = makeProvider()
        let input = "你好 \nworld  "
        let items = provider.items(for: input)
        #expect(items.map(\.keyword) == ["b64", "b64d", "tr"])
        #expect(tools.requests.isEmpty)
        #expect(urls.opened.isEmpty)
        for item in items { try await item.primaryAction?.run() }
        #expect(tools.requests == [
            ToolOpenRequest(kind: .base64, mode: "encode", input: input),
            ToolOpenRequest(kind: .base64, mode: "decode", input: input),
            ToolOpenRequest(kind: .translation, mode: "translation", input: input)
        ])
    }

    @Test func matchingFiltersActionNamesAndKeywords() {
        let (provider, _, _, _, _) = makeProvider()
        #expect(provider.items(for: "hello", matching: " B64D ").map(\.keyword) == ["b64d"])
        #expect(provider.items(for: "hello", matching: "翻译").map(\.keyword) == ["tr"])
        #expect(provider.items(for: "https://example.com", matching: "浏览器").count == 1)
        #expect(provider.items(for: "https://example.com", matching: "urld").map(\.keyword) == ["urld"])
        #expect(provider.items(for: "{}", matching: "base64").isEmpty)
        #expect(provider.items(for: "  ").isEmpty)
    }

    @Test func disabledSettingsRemoveActionsAndAreCheckedAgainAtExecution() async throws {
        let (provider, settings, tools, urls, _) = makeProvider()
        let existing = try #require(provider.items(for: "hello", matching: "b64d").first)
        settings.setProviderEnabled("text", to: false)
        #expect(provider.items(for: "hello").map(\.keyword) == ["tr"])
        #expect(provider.items(for: "{}").isEmpty)
        #expect(provider.items(for: "https://example.com").map(\.keyword) == [nil])
        try await existing.primaryAction?.run()
        #expect(tools.requests.isEmpty)
        settings.setProviderEnabled("translation", to: false)
        settings.setProviderEnabled("web", to: false)
        #expect(provider.items(for: "hello").isEmpty)
        #expect(provider.items(for: "https://example.com").isEmpty)
        #expect(urls.opened.isEmpty)
    }

    @Test func noteCaptureAndCreateActionsAppearWhenNotesProviderEnabled() async throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let tools = MockToolOpener()
        let urls = MockURLOpener()
        let feedback = MockFeedback()
        let notes = MockContentNoteOpener()
        let provider = ContentActionProvider(settings: settings, toolOpener: tools, urlOpener: urls, feedback: feedback, noteOpener: notes)

        let items = provider.items(for: "需要保留的排查笔记", matching: "速记")
        #expect(items.map(\.id) == ["content:notes.capture"])
        try await items[0].primaryAction?.run()
        #expect(notes.captured == ["需要保留的排查笔记"])
        #expect(feedback.messages.last?.contains("速记") == true)

        let createItems = provider.items(for: "https://example.com", matching: "便笺")
        #expect(createItems.map(\.id) == ["content:notes.capture", "content:notes.create"])
        try await createItems[1].primaryAction?.run()
        #expect(notes.created == ["https://example.com"])

        settings.setProviderEnabled("notes", to: false)
        #expect(provider.items(for: "需要保留的排查笔记", matching: "便笺").isEmpty)
    }

    @Test func pastedContentOffersOpenAIPrefillWithoutAutoSending() async throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let tools = MockToolOpener()
        let urls = MockURLOpener()
        let feedback = MockFeedback()
        var aiRequests: [QuickAIRequest] = []
        let provider = ContentActionProvider(
            settings: settings,
            toolOpener: tools,
            urlOpener: urls,
            feedback: feedback,
            openAI: { aiRequests.append($0) }
        )

        for sample in ["一段待分析日志", "{\"err\":500}", "https://example.com/docs"] {
            let matched = provider.items(for: sample, matching: "ai")
            #expect(matched.map(\.id) == ["content:ai.ask"])
            #expect(matched[0].keyword == "ai")
            #expect(matched[0].primaryAction?.presentation == .openWindow)
            try await matched[0].primaryAction?.run()
        }

        #expect(aiRequests.count == 3)
        #expect(aiRequests.allSatisfy { $0.autoSend == false })
        #expect(aiRequests.map(\.prompt) == ["一段待分析日志", "{\"err\":500}", "https://example.com/docs"])
    }
}

@MainActor
private final class MockContentNoteOpener: LocalNoteOpening {
    var captured: [String] = []
    var created: [String] = []
    func createNote() {}
    func createNote(with text: String) { created.append(text) }
    func quickCapture(_ text: String) throws -> LocalNoteRecord {
        captured.append(text)
        return LocalNoteRecord(title: LocalNoteStore.dailyNoteTitle(), titleIsAutomatic: false)
    }
    func openNote(_ id: UUID) {}
}
