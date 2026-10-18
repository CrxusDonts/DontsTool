import Foundation
import Testing
@testable import DontsToolCore

@Suite("独立工具文档") @MainActor
struct ToolDocumentStoreTests {
    @Test func sameKindDocumentsHaveIndependentDraftsAndResults() async {
        let store = ToolDocumentStore()
        let first = store.create(ToolOpenRequest(kind: .base64, input: "hello"))
        let second = store.create(ToolOpenRequest(kind: .base64, mode: "decode", input: "d29ybGQ="))
        #expect(first.id != second.id)
        #expect(first.session !== second.session)
        await first.session.perform()
        await second.session.perform()
        #expect(first.session.output == "aGVsbG8=")
        #expect(second.session.output == "world")
        first.session.input = "changed"
        #expect(!first.session.isFresh)
        #expect(second.session.input == "d29ybGQ=")
        #expect(second.session.isFresh)
    }

    @Test func pinningIsPerDocumentAndSurvivesDraftReopening() async throws {
        let store = ToolDocumentStore()
        let first = store.create(ToolOpenRequest(kind: .json, input: "true"))
        let peer = store.create(ToolOpenRequest(kind: .json))
        await first.session.perform()
        first.isPinned = true
        #expect(!peer.isPinned)
        #expect(first.session.canCopy)
        #expect(first.session.output == "true")
        store.close(first.id)
        let reopened = try #require(store.reopen(first.id))
        #expect(reopened.isPinned)
        first.isPinned = false
        #expect(!reopened.isPinned)
        #expect(!store.create(ToolOpenRequest(kind: .base64)).isPinned)
        #expect(first.session.canCopy)
    }

    @Test func defaultNamesUseIndependentMonotonicCounters() {
        let store = ToolDocumentStore()
        let first = store.create(ToolOpenRequest(kind: .json))
        let base64 = store.create(ToolOpenRequest(kind: .base64))
        store.rename(first.id, to: "配置")
        store.close(first.id)
        let second = store.create(ToolOpenRequest(kind: .json))
        #expect(base64.title == "未命名 Base64 1")
        #expect(second.title == "未命名 JSON 2")
        #expect(first.title == "配置")
    }

    @Test func translationPreferenceDoesNotInvalidateInitialUUID() {
        let store = ToolDocumentStore(translationTarget: "ja")
        let document = store.create(ToolOpenRequest(kind: .uuid))
        #expect(UUID(uuidString: document.session.output) != nil)
        #expect(document.session.canCopy)
        store.close(document.id)
        #expect(document.session.canCopy)
    }

    @Test func renameAndSideLabelsDoNotInvalidateResultOrIdentity() async {
        let store = ToolDocumentStore()
        let document = store.create(ToolOpenRequest(kind: .json, input: "true"))
        let identity = document.id
        await document.session.perform()
        store.rename(identity, to: " \n API 响应 \t")
        document.leftTitle = "生产"
        document.rightTitle = "预期"
        #expect(document.id == identity)
        #expect(document.title == "API 响应")
        #expect(document.session.output == "true")
        #expect(document.session.canCopy)
        store.rename(identity, to: " \n ")
        #expect(document.title == "API 响应")
        store.rename(identity, to: String(repeating: "👨‍👩‍👧‍👦", count: 85))
        #expect(document.title.count == 80)
        #expect(document.session.canCopy)
    }

    @Test func duplicateCopiesEveryDraftOptionAndLabelsWithoutSharingSession() throws {
        let store = ToolDocumentStore()
        let source = store.create(ToolOpenRequest(kind: .json, mode: "unescape", input: "draft"))
        source.session.compareLeft = "left"
        source.session.compareRight = "right"
        source.session.comparing = true
        source.session.urlSafe = true
        source.session.form = true
        source.session.bare = true
        source.session.uppercase = true
        source.session.hyphens = false
        source.session.uuidCount = "42"
        source.session.unit = .milliseconds
        source.session.utc = true
        source.session.target = "en"
        source.leftTitle = "本地"
        source.rightTitle = "线上"
        store.rename(source.id, to: "配置")
        let copy = try #require(store.duplicate(source.id))
        #expect(copy.id != source.id)
        #expect(copy.session !== source.session)
        #expect(copy.kind == .json)
        #expect(copy.title == "配置 副本")
        #expect(copy.leftTitle == "本地")
        #expect(copy.rightTitle == "线上")
        #expect(copy.session.input == "draft")
        #expect(copy.session.compareLeft == "left")
        #expect(copy.session.compareRight == "right")
        #expect(copy.session.comparing)
        #expect(copy.session.mode == "unescape")
        #expect(copy.session.urlSafe && copy.session.form && copy.session.bare)
        #expect(copy.session.uppercase && !copy.session.hyphens)
        #expect(copy.session.uuidCount == "42")
        #expect(copy.session.unit == .milliseconds && copy.session.utc)
        #expect(copy.session.target == "en")
        copy.session.input = "independent"
        copy.leftTitle = "副本左侧"
        #expect(source.session.input == "draft")
        #expect(source.leftTitle == "本地")
    }

    @Test func creationAndDuplicationDoNotSendTranslationRequests() async throws {
        let translator = DocumentTestTranslator()
        let store = ToolDocumentStore(translator: translator, translationTarget: "ja")
        let source = store.create(ToolOpenRequest(kind: .translation, input: "original"))
        #expect(source.session.target == "ja")
        let copy = try #require(store.duplicate(source.id))
        #expect(translator.inputs.isEmpty)
        #expect(copy.session.output.isEmpty)
        #expect(!copy.session.isRunning)
        copy.session.run()
        while translator.pending["original"] == nil { await Task.yield() }
        #expect(translator.inputs == ["original"])
        store.close(copy.id)
        translator.finish("original", with: "translation")
    }

    @Test func closingIdleDocumentPreservesFreshResultAndReopensSameDraft() async throws {
        let store = ToolDocumentStore()
        let document = store.create(ToolOpenRequest(kind: .base64, mode: "decode", input: "aGk="))
        await document.session.perform()
        store.rename(document.id, to: "报文")
        store.close(document.id)
        #expect(document.isClosed)
        #expect(store.openDocuments.isEmpty)
        #expect(document.session.canCopy)
        #expect(store.recentlyClosed.map(\.id) == [document.id])
        let reopened = try #require(store.reopen(document.id))
        #expect(reopened === document)
        #expect(!document.isClosed)
        #expect(document.title == "报文")
        #expect(document.session.mode == "decode")
        #expect(document.session.input == "aGk=")
        #expect(document.session.output == "hi")
        #expect(store.recentlyClosed.isEmpty)
    }

    @Test func closingAfterScheduledOperationCompletesPreservesResult() async {
        let store = ToolDocumentStore()
        let document = store.create(ToolOpenRequest(kind: .base64, input: "hello"))
        document.session.run()
        while document.session.output.isEmpty { await Task.yield() }
        store.close(document.id)
        #expect(document.session.output == "aGVsbG8=")
        #expect(document.session.canCopy)
    }

    @Test func duplicateOmitsComputedOutputAndPendingReplacement() async throws {
        let store = ToolDocumentStore()
        let source = store.create(ToolOpenRequest(kind: .base64, input: "hello"))
        await source.session.perform()
        source.session.accept(ToolOpenRequest(kind: .base64, mode: "decode", input: "d29ybGQ="))
        let copy = try #require(store.duplicate(source.id))
        #expect(copy.session.input == "hello")
        #expect(copy.session.mode == "encode")
        #expect(copy.session.output.isEmpty)
        #expect(copy.session.pendingRequest == nil)
        #expect(!copy.session.canCopy)
        #expect(source.session.output == "aGVsbG8=")
        #expect(source.session.pendingRequest != nil)
        #expect(source.session.canCopy)
    }

    @Test func activationAndClosingTrackSeparateRecency() {
        let store = ToolDocumentStore()
        let first = store.create(ToolOpenRequest(kind: .json))
        let second = store.create(ToolOpenRequest(kind: .json))
        let third = store.create(ToolOpenRequest(kind: .url))
        store.activate(first.id)
        #expect(store.openDocuments.map(\.id) == [first.id, third.id, second.id])
        store.close(second.id)
        store.close(first.id)
        store.close(second.id)
        store.activate(second.id)
        #expect(store.recentlyClosed.map(\.id) == [first.id, second.id])
        #expect(store.openDocuments.map(\.id) == [third.id])
    }

    @Test func closedDraftCapEvictsOldestAndKeepsOpenDocuments() {
        let store = ToolDocumentStore()
        let open = store.create(ToolOpenRequest(kind: .json, input: "keep"))
        let closed = (0..<11).map { _ in store.create(ToolOpenRequest(kind: .json)) }
        for document in closed { store.close(document.id) }
        #expect(store.recentlyClosed.count == 10)
        #expect(store.documents.count == 11)
        #expect(store.reopen(closed[0].id) == nil)
        #expect(store.duplicate(closed[0].id) == nil)
        #expect(store.recentlyClosed.first?.id == closed[10].id)
        #expect(store.openDocuments.first === open)
        #expect(open.session.input == "keep")
    }

    @Test func closingTranslationRejectsLateResponseWithoutCancellingPeer() async {
        let translator = DocumentTestTranslator()
        let store = ToolDocumentStore(translator: translator)
        let first = store.create(ToolOpenRequest(kind: .translation, input: "one"))
        let second = store.create(ToolOpenRequest(kind: .translation, input: "two"))
        first.session.run()
        second.session.run()
        while translator.pending.count != 2 { await Task.yield() }
        store.close(first.id)
        #expect(!first.session.isRunning)
        #expect(second.session.isRunning)
        translator.finish("one", with: "旧译文")
        translator.finish("two", with: "第二份译文")
        while translator.returned.count != 2 || second.session.isRunning { await Task.yield() }
        #expect(translator.cancelled == ["one"])
        #expect(first.session.output.isEmpty)
        #expect(!first.session.isFresh)
        #expect(second.session.output == "第二份译文")
        #expect(second.session.canCopy)
    }
}

@MainActor private final class DocumentTestTranslator: TranslationServicing {
    var isConfigured = true
    var inputs: [String] = []
    var returned: [String] = []
    var cancelled: [String] = []
    var pending: [String: CheckedContinuation<String, Never>] = [:]
    func translate(_ text: String, target: String) async throws -> String {
        inputs.append(text)
        let result = await withCheckedContinuation { pending[text] = $0 }
        returned.append(text)
        if Task.isCancelled { cancelled.append(text) }
        return result
    }
    func finish(_ input: String, with result: String) {
        pending.removeValue(forKey: input)?.resume(returning: result)
    }
}
