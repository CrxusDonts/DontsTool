import AppKit
import ApplicationServices
import DontsToolCore
import os

@MainActor
final class SystemGeminiAppController: GeminiAppControlling {
    var canAutomate: Bool { AXIsProcessTrusted() }

    private let logger = Logger(subsystem: "com.donts.DontsTool", category: "gemini-handoff")
    private var lastReadDiagnostic: String?
    private let worker = GeminiAXWorker()
    private let handoff = GeminiHandoffCancellation(monitor: SystemGeminiEscapeMonitor())
    private var cancellation = GeminiCancellationFlag()
    private var applicationURL: URL?
    private var processIdentifier: pid_t?

    func open(_ application: URL) async throws {
        try Task.checkCancellation()
        cancellation = handoff.prepare()
        lastReadDiagnostic = nil
        logger.notice("开始打开 Gemini，等待应用激活")
        let target = application.resolvingSymlinksInPath().standardizedFileURL
        guard target.isFileURL,
              Bundle(url: target)?.bundleIdentifier == "com.google.GeminiMacOS" else {
            throw GeminiAppAutomationError.applicationUnavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let running: NSRunningApplication
        do {
            running = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        } catch {
            throw GeminiAppAutomationError.applicationUnavailable
        }
        guard !running.isTerminated,
              running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target else {
            throw GeminiAppAutomationError.applicationUnavailable
        }
        running.activate(options: [.activateAllWindows])
        logger.notice("Gemini 已打开，已请求激活全部窗口")
        applicationURL = target
        processIdentifier = running.processIdentifier
        await worker.bind(pid: running.processIdentifier, cancellation: cancellation)
    }

    func newConversation() async throws {
        try checkCancellation()
        guard let applicationURL, let processIdentifier else { throw GeminiAppAutomationError.applicationUnavailable }
        logger.notice("已确认输入框为空，开始新建 Gemini 对话")
        try await worker.prepareForNewConversation()
        try checkCancellation()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        // Gemini's installed Ask Gemini App Intent uses this route; AX must still confirm the landing state.
        let route = URL(string: "googlegemini://newchat")!
        let running: NSRunningApplication
        do {
            running = try await NSWorkspace.shared.open([route], withApplicationAt: applicationURL,
                                                        configuration: configuration)
        } catch {
            throw GeminiAppAutomationError.actionFailed
        }
        guard running.processIdentifier == processIdentifier,
              running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == applicationURL else {
            throw GeminiAppAutomationError.contextChanged
        }
        running.activate(options: [.activateAllWindows])
        logger.notice("已打开 Gemini 新对话路由，等待确认输入框")
    }

    func readComposer() async throws -> GeminiComposerState {
        guard processIdentifier != nil else { throw GeminiAppAutomationError.applicationUnavailable }
        handoff.begin()
        try checkCancellation()
        let value = try await worker.read()
        let diagnostic = "前台=\(value.isFrontmost)，输入框=\(value.text != nil)，新对话=\(value.isNewConversation)，可发送=\(value.canSend)，已提交=\(value.submissionAccepted)"
        if diagnostic != lastReadDiagnostic {
            logger.notice("Gemini 状态：\(diagnostic, privacy: .public)")
            lastReadDiagnostic = diagnostic
        }
        return GeminiComposerState(text: value.text, isNewConversation: value.isNewConversation,
                                   isFrontmost: value.isFrontmost, canSend: value.canSend,
                                   submissionAccepted: value.submissionAccepted)
    }

    func setPrompt(_ question: String) async throws {
        try checkCancellation()
        logger.notice("开始写入 Gemini 输入框")
        try await worker.write(question)
        logger.notice("Gemini 输入框写入操作已完成，等待读回确认")
    }

    func submit() async throws {
        try checkCancellation()
        logger.notice("已确认问题完整，执行一次 Gemini 发送")
        try await worker.submit()
    }

    func finishHandoff() { handoff.finish() }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
    }
}

private actor GeminiAXWorker {
    private var session: GeminiAXSession<SystemGeminiAccessibility>?

    func bind(pid: pid_t, cancellation: GeminiCancellationFlag) {
        session = GeminiAXSession(ax: SystemGeminiAccessibility(cancellation: cancellation), pid: pid)
    }

    func prepareForNewConversation() throws {
        guard session != nil else { throw GeminiAppAutomationError.applicationUnavailable }
        try session!.prepareForNewConversation()
    }

    func read() throws -> GeminiAXSnapshot {
        guard session != nil else { throw GeminiAppAutomationError.applicationUnavailable }
        return try session!.read()
    }

    func write(_ question: String) throws {
        guard session != nil else { throw GeminiAppAutomationError.applicationUnavailable }
        try session!.write(question)
    }

    func submit() throws {
        guard session != nil else { throw GeminiAppAutomationError.applicationUnavailable }
        try session!.submit()
    }
}

private struct SystemGeminiAccessibility: GeminiAccessibility {
    let cancellation: GeminiCancellationFlag
    var isCancelled: Bool { cancellation.isCancelled }
    var trusted: Bool { AXIsProcessTrusted() }

    var frontmostPID: Int32? {
        let system = AXUIElementCreateSystemWide()
        guard let application = element(kAXFocusedApplicationAttribute, of: system) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(application, &pid) == .success else { return nil }
        return pid
    }

    func focusedWindow(pid: Int32) -> AXUIElement? {
        element(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(pid))
    }

    func metadata(_ value: AXUIElement) -> GeminiAXMetadata {
        GeminiAXMetadata(role: attribute(kAXRoleAttribute, of: value) as? String ?? "",
                         identifier: attribute(kAXIdentifierAttribute, of: value) as? String ?? "")
    }

    func children(_ value: AXUIElement) -> [AXUIElement] {
        guard !Task.isCancelled, !isCancelled else { return [] }
        AXUIElementSetMessagingTimeout(value, 0.15)
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(value, kAXChildrenAttribute as CFString, &count) == .success,
              count > 0 else { return [] }
        var result: CFArray?
        guard AXUIElementCopyAttributeValues(value, kAXChildrenAttribute as CFString, 0,
                                             min(count, 251), &result) == .success else { return [] }
        return result as? [AXUIElement] ?? []
    }

    func promptDescription(_ value: AXUIElement) -> String? { attribute(kAXDescriptionAttribute, of: value) as? String }
    func text(_ value: AXUIElement) -> String? { attribute(kAXValueAttribute, of: value) as? String }
    func isEnabled(_ value: AXUIElement) -> Bool { attribute(kAXEnabledAttribute, of: value) as? Bool ?? false }

    func setText(_ text: String, of value: AXUIElement) throws -> Bool {
        try checkCancellation()
        guard trusted else { throw GeminiAppAutomationError.accessibilityUnavailable }
        AXUIElementSetMessagingTimeout(value, 0.15)
        try checkCancellation()
        return AXUIElementSetAttributeValue(value, kAXValueAttribute as CFString, text as CFString) == .success
    }

    func press(_ value: AXUIElement) throws -> Bool {
        try checkCancellation()
        guard trusted else { throw GeminiAppAutomationError.accessibilityUnavailable }
        AXUIElementSetMessagingTimeout(value, 0.15)
        try checkCancellation()
        return AXUIElementPerformAction(value, kAXPressAction as CFString) == .success
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
    }

    private func element(_ name: String, of value: AXUIElement) -> AXUIElement? {
        guard let result = attribute(name, of: value), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(result, to: AXUIElement.self)
    }

    private func attribute(_ name: String, of value: AXUIElement) -> CFTypeRef? {
        guard !Task.isCancelled, !isCancelled else { return nil }
        AXUIElementSetMessagingTimeout(value, 0.15)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(value, name as CFString, &result) == .success else { return nil }
        return result
    }
}
