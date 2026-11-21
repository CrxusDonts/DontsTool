import AppKit
import DontsToolCore
import Foundation
import Testing

@Suite("Quick AI 原生对话窗口", .serialized)
@MainActor
struct QuickAIWindowTests {
    @Test func markdownParserSplitsProseAndClosedCodeBlocks() {
        let markdown = """
        这是开头说明，包含 `inline` 代码。

        ```swift
        let answer = 42
        print(answer)
        ```

        中间段落。

        ~~~
        plain block
        ~~~
        """

        let blocks = QuickAIMarkdownParser.parse(markdown)
        #expect(blocks.count == 4)
        #expect(blocks[0] == .prose(id: 0, text: "这是开头说明，包含 `inline` 代码。"))
        #expect(blocks[1] == .codeBlock(id: 1, language: "swift", code: "let answer = 42\nprint(answer)", isClosed: true))
        #expect(blocks[2] == .prose(id: 2, text: "中间段落。"))
        #expect(blocks[3] == .codeBlock(id: 3, language: nil, code: "plain block", isClosed: true))
    }

    @Test func markdownParserPreservesUnclosedStreamingCodeFence() {
        let partial = """
        正在生成代码：

        ```python
        def fib(n):
            return n if n <= 1 else fib(n - 1) + fib(n - 2)
        """

        let blocks = QuickAIMarkdownParser.parse(partial)
        #expect(blocks.count == 2)
        #expect(blocks[0] == .prose(id: 0, text: "正在生成代码："))
        #expect(blocks[1] == .codeBlock(
            id: 1,
            language: "python",
            code: "def fib(n):\n    return n if n <= 1 else fib(n - 1) + fib(n - 2)",
            isClosed: false
        ))
    }

    @Test func windowManagerOpensStreamsPinsAndRecordsUsage() async throws {
        _ = NSApplication.shared
        let service = MockAIChatService(mode: .chunks(["你好，", "世界！"]))
        let suiteName = "dontstool.quickai.usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let usage = UsageStore(defaults: defaults)
        let manager = QuickAIWindowManager(aiService: service, usage: usage)
        defer { manager.shutdown() }

        let session = manager.open(QuickAIRequest(title: "代码解释", prompt: "解释闭包", autoSend: true))
        let window = try #require(manager.window(for: session.id))

        #expect(manager.openWindowCount == 1)
        #expect(window.title == "代码解释")
        #expect(window.level == .normal)
        #expect(usage.record(for: QuickAIWindowManager.usageCanonicalKey)?.count == 1)

        await session.waitForCurrentStream()
        #expect(!session.isStreaming)
        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[0].content == "解释闭包")
        #expect(session.messages[1].role == .assistant)
        #expect(session.messages[1].content == "你好，世界！")

        session.isPinned = true
        #expect(window.level == .floating)
        session.isPinned = false
        #expect(window.level == .normal)

        var openedSettings = 0
        manager.onOpenSettings = { openedSettings += 1 }
        manager.openSettings()
        #expect(openedSettings == 1)
    }

    @Test func prefillOnlyRequestDoesNotAutoSend() {
        _ = NSApplication.shared
        let service = MockAIChatService(mode: .chunks(["不应触发"]))
        let manager = QuickAIWindowManager(aiService: service)
        defer { manager.shutdown() }

        let session = manager.open(QuickAIRequest(title: "AI 快问", prompt: "预填内容", autoSend: false))
        #expect(session.draftPrompt == "预填内容")
        #expect(session.messages.isEmpty)
        #expect(!session.isStreaming)
        #expect(service.streamCallCount == 0)
    }

    @Test func closingWindowAndShutdownCancelActiveStreams() async throws {
        _ = NSApplication.shared
        let cancelledFlag = LockedFlag()
        let service = MockAIChatService(mode: .suspendUntilCancelled(cancelledFlag))
        let manager = QuickAIWindowManager(aiService: service)
        defer { manager.shutdown() }

        let first = manager.open(QuickAIRequest(prompt: "长任务 1", autoSend: true))
        #expect(first.isStreaming)
        #expect(manager.openWindowCount == 1)

        await waitUntil { first.messages.last?.content == "思考中" }

        manager.closeWindow(first.id)
        await first.waitForCurrentStream()
        #expect(!first.isStreaming)
        #expect(manager.openWindowCount == 0)
        #expect(cancelledFlag.value)

        // 验证多窗口 shutdown 同样清理并取消流
        let secondFlag = LockedFlag()
        let secondService = MockAIChatService(mode: .suspendUntilCancelled(secondFlag))
        let secondManager = QuickAIWindowManager(aiService: secondService)
        let s1 = secondManager.open(QuickAIRequest(prompt: "任务 A", autoSend: true))
        let s2 = secondManager.newWindow()
        #expect(secondManager.openWindowCount == 2)
        #expect(s1.isStreaming)
        #expect(!s2.isStreaming)

        await waitUntil { s1.messages.last?.content == "思考中" }
        secondManager.shutdown()
        await s1.waitForCurrentStream()
        #expect(secondManager.openWindowCount == 0)
        #expect(!s1.isStreaming)
        #expect(secondFlag.value)
    }

    @Test func composerGuardsChineseIMECompositionForEnterAndEscape() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let composer = QuickAIComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        window.contentView = composer
        window.makeFirstResponder(composer)
        defer { window.orderOut(nil) }

        var submitCount = 0
        var escapeCount = 0
        var newWindowCount = 0
        composer.onSubmit = { submitCount += 1 }
        composer.onEscape = { escapeCount += 1 }
        composer.onNewWindow = { newWindowCount += 1 }

        let returnEvent = try makeKeyEvent(keyCode: 36, characters: "\r", modifiers: [])
        let escapeEvent = try makeKeyEvent(keyCode: 53, characters: "\u{1B}", modifiers: [])
        let cmdNEvent = try makeKeyEvent(keyCode: 45, characters: "n", modifiers: [.command])

        // 模拟中文输入法组合态：Return 交由输入法处理，不得误发送
        composer.setMarkedText(
            "nihao",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        #expect(composer.hasMarkedText())
        #expect(composer.isComposing)
        composer.keyDown(with: returnEvent)
        #expect(submitCount == 0)

        // 模拟中文输入法组合态：Escape 交由输入法取消候选词，不得误关闭窗口
        composer.string = ""
        composer.setMarkedText(
            "nihao",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        #expect(composer.hasMarkedText())
        composer.keyDown(with: escapeEvent)
        #expect(escapeCount == 0)

        // 模拟中文输入法组合态：⌘N 不得抢占输入法快捷键
        composer.string = ""
        composer.setMarkedText(
            "nihao",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        #expect(composer.hasMarkedText())
        #expect(!composer.performKeyEquivalent(with: cmdNEvent))
        #expect(newWindowCount == 0)

        // 结束组合态，确认常规按键正常生效
        composer.insertText("你好", replacementRange: composer.markedRange())
        #expect(!composer.hasMarkedText())
        #expect(composer.string == "你好")

        let shiftReturnEvent = try makeKeyEvent(keyCode: 36, characters: "\r", modifiers: [.shift])
        composer.keyDown(with: shiftReturnEvent)
        #expect(submitCount == 0)
        #expect(composer.string == "你好\n")

        composer.keyDown(with: returnEvent)
        #expect(submitCount == 1)

        composer.keyDown(with: escapeEvent)
        #expect(escapeCount == 1)

        #expect(composer.performKeyEquivalent(with: cmdNEvent))
        #expect(newWindowCount == 1)
    }

    @Test func quickAIWindowReflectsBoundModelProfileAndUnconfiguredState() throws {
        _ = NSApplication.shared
        let suiteName = "dontstool.quickai.profiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let secrets = InMemoryQuickAISecrets()
        let service = RemoteAIChatService(settings: settings, secrets: secrets, purpose: .quickAI)
        let manager = QuickAIWindowManager(aiService: service)
        defer { manager.shutdown() }

        let session = manager.open(QuickAIRequest(title: "AI 快问", prompt: "", autoSend: false))
        let window = try #require(manager.window(for: session.id))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(!session.isConfigured)
        #expect(session.activeProfileName == nil)

        let defaultProfile = AIModelProfile(
            name: "主力模型",
            format: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1-mini"
        )
        let quickAIProfile = AIModelProfile(
            name: "DeepSeek Flash",
            format: .openAIChatCompletions,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat"
        )
        settings.upsertAIModelProfile(defaultProfile, makeDefault: true)
        settings.saveAPIKey("sk-default", for: defaultProfile, secrets: secrets)
        settings.upsertAIModelProfile(quickAIProfile)
        settings.saveAPIKey("sk-quick", for: quickAIProfile, secrets: secrets)
        settings.setQuickAIAIModelProfileID(quickAIProfile.id)

        #expect(session.isConfigured)
        #expect(session.activeProfileName == "DeepSeek Flash")
        #expect(session.activeModelDisplay == "DeepSeek Flash · deepseek-chat")
        #expect(session.activeFormat == .openAIChatCompletions)

        // 触发重排确保配置态与未配置态均正常渲染
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()

        // 取消单独绑定后应回退到默认模型
        settings.setQuickAIAIModelProfileID(nil)
        #expect(session.activeProfileName == "主力模型")
        #expect(session.activeModelDisplay == "主力模型 · gpt-4.1-mini")
    }

    private func waitUntil(
        maxAttempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<maxAttempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeKeyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func setTrue() {
        lock.withLock { storage = true }
    }
}

private final class InMemoryQuickAISecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func secret(for account: String) -> String? {
        lock.withLock { values[account] }
    }

    func setSecret(_ value: String?, for account: String) {
        lock.withLock {
            if let value, !value.isEmpty {
                values[account] = value
            } else {
                values.removeValue(forKey: account)
            }
        }
    }
}

@MainActor
private final class MockAIChatService: AIChatServicing {
    enum Mode {
        case chunks([String])
        case suspendUntilCancelled(LockedFlag)
    }

    let mode: Mode
    var isConfigured: Bool = true
    var activeModelDisplay: String = "OpenAI Responses · gpt-4.1-mini"
    var activeFormat: AIAPIFormat = .openAIResponses
    private(set) var streamCallCount = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func complete(messages: [AIChatMessage], systemPrompt: String?) async throws -> String {
        switch mode {
        case .chunks(let chunks):
            chunks.joined()
        case .suspendUntilCancelled:
            ""
        }
    }

    func stream(messages: [AIChatMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        streamCallCount += 1
        switch mode {
        case .chunks(let chunks):
            return AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        case .suspendUntilCancelled(let flag):
            return AsyncThrowingStream { continuation in
                continuation.yield("思考中")
                continuation.onTermination = { _ in
                    flag.setTrue()
                }
            }
        }
    }
}
