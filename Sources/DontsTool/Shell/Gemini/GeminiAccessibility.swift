import Foundation

struct GeminiAXMetadata {
    let role: String
    let identifier: String
}

protocol GeminiAccessibility {
    associatedtype Element: Equatable
    var trusted: Bool { get }
    var isCancelled: Bool { get }
    var frontmostPID: Int32? { get }
    func focusedWindow(pid: Int32) -> Element?
    func metadata(_ element: Element) -> GeminiAXMetadata
    func children(_ element: Element) -> [Element]
    func promptDescription(_ element: Element) -> String?
    func text(_ element: Element) -> String?
    func isEnabled(_ element: Element) -> Bool
    func setText(_ text: String, of element: Element) throws -> Bool
    func press(_ element: Element) throws -> Bool
}

extension GeminiAccessibility {
    var isCancelled: Bool { false }
}

struct GeminiAXSnapshot: Sendable {
    let text: String?
    let isNewConversation: Bool
    let isFrontmost: Bool
    let canSend: Bool
    let submissionAccepted: Bool
}

enum GeminiAppAutomationError: LocalizedError {
    case accessibilityUnavailable
    case applicationUnavailable
    case contextChanged
    case composerUnavailable
    case composerNotReady
    case draftPresent
    case newConversationUnconfirmed
    case promptChanged
    case submissionUnavailable
    case actionFailed
    case inspectionTimedOut

    var errorDescription: String? {
        switch self {
        case .accessibilityUnavailable: "请先在系统设置中为 DontsTool 开启辅助功能权限。"
        case .applicationUnavailable: "无法打开已安装的 Gemini 应用。"
        case .contextChanged: "Gemini 的活动应用或窗口已改变，请重新发起提问。"
        case .composerUnavailable, .composerNotReady: "无法确认 Gemini 的输入框，请检查应用是否已登录并完成加载。"
        case .draftPresent: "Gemini 中有尚未发送的草稿，请先处理草稿。"
        case .newConversationUnconfirmed: "无法确认 Gemini 已进入新对话。"
        case .promptChanged: "Gemini 输入内容已改变，已停止发送。"
        case .submissionUnavailable: "Gemini 的发送按钮尚不可用，或本次发送已经尝试。"
        case .inspectionTimedOut: "Gemini 界面响应超时，已停止自动操作。"
        case .actionFailed: "Gemini 未接受自动操作，请检查应用窗口后重试。"
        }
    }
}

struct GeminiAXSession<AX: GeminiAccessibility> {
    let ax: AX
    let pid: Int32
    private var boundWindow: AX.Element?
    private var writtenPrompt: String?
    private var submissionAttempted = false
    private var pendingNewLanding = false

    init(ax: AX, pid: Int32) {
        self.ax = ax
        self.pid = pid
    }

    mutating func read() throws -> GeminiAXSnapshot {
        do {
            return try inspect().snapshot
        } catch GeminiAppAutomationError.composerNotReady {
            try checkCancellation()
            guard ax.trusted else { throw GeminiAppAutomationError.accessibilityUnavailable }
            return GeminiAXSnapshot(text: nil, isNewConversation: false,
                                    isFrontmost: ax.frontmostPID == pid, canSend: false, submissionAccepted: false)
        }
    }

    mutating func prepareForNewConversation() throws {
        let current = try inspect().snapshot
        guard current.isFrontmost else { throw GeminiAppAutomationError.contextChanged }
        guard current.text == "" else { throw GeminiAppAutomationError.draftPresent }
        boundWindow = nil
        pendingNewLanding = true
        writtenPrompt = nil
        submissionAttempted = false
    }

    mutating func write(_ question: String) throws {
        let current = try inspect()
        guard current.snapshot.isFrontmost else { throw GeminiAppAutomationError.contextChanged }
        guard current.snapshot.text == "" else { throw GeminiAppAutomationError.draftPresent }
        guard current.snapshot.isNewConversation else { throw GeminiAppAutomationError.newConversationUnconfirmed }
        guard !submissionAttempted, let prompt = current.prompt else { throw GeminiAppAutomationError.composerUnavailable }
        try requireBoundContext()
        guard try ax.setText(question, of: prompt) else { throw GeminiAppAutomationError.actionFailed }
        writtenPrompt = question
    }

    mutating func submit() throws {
        guard !submissionAttempted, let writtenPrompt else { throw GeminiAppAutomationError.submissionUnavailable }
        let current = try inspect()
        guard current.snapshot.isFrontmost else { throw GeminiAppAutomationError.contextChanged }
        guard current.snapshot.isNewConversation else { throw GeminiAppAutomationError.newConversationUnconfirmed }
        guard current.snapshot.text == writtenPrompt else { throw GeminiAppAutomationError.promptChanged }
        guard current.snapshot.canSend, let send = current.send else { throw GeminiAppAutomationError.submissionUnavailable }
        try requireBoundContext()
        // A failed AXPress can still have reached the application; this request must never retry it.
        submissionAttempted = true
        guard try ax.press(send) else { throw GeminiAppAutomationError.actionFailed }
    }

    private func checkCancellation(deadline: ContinuousClock.Instant? = nil) throws {
        try Task.checkCancellation()
        guard !ax.isCancelled else { throw CancellationError() }
        if let deadline, ContinuousClock.now >= deadline { throw GeminiAppAutomationError.inspectionTimedOut }
    }

    private func requireBoundContext() throws {
        try checkCancellation()
        guard ax.trusted else { throw GeminiAppAutomationError.accessibilityUnavailable }
        guard let boundWindow else { throw GeminiAppAutomationError.contextChanged }
        try requireContext(window: boundWindow)
    }

    private func requireContext(window: AX.Element) throws {
        try checkCancellation()
        guard ax.trusted else { throw GeminiAppAutomationError.accessibilityUnavailable }
        guard ax.frontmostPID == pid, ax.focusedWindow(pid: pid) == window else {
            throw GeminiAppAutomationError.contextChanged
        }
    }

    private mutating func inspect() throws -> (snapshot: GeminiAXSnapshot, prompt: AX.Element?, send: AX.Element?) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        try checkCancellation(deadline: deadline)
        guard ax.trusted else { throw GeminiAppAutomationError.accessibilityUnavailable }
        guard ax.frontmostPID == pid else {
            return (GeminiAXSnapshot(text: nil, isNewConversation: false, isFrontmost: false,
                                     canSend: false, submissionAccepted: false), nil, nil)
        }
        try checkCancellation(deadline: deadline)
        let focusedWindow = ax.focusedWindow(pid: pid)
        try checkCancellation(deadline: deadline)
        guard let window = focusedWindow else { throw GeminiAppAutomationError.composerNotReady }
        if let boundWindow, window != boundWindow { throw GeminiAppAutomationError.contextChanged }
        if !pendingNewLanding { boundWindow = window }
        var queue: [(AX.Element, Int)] = [(window, 0)]
        var visited: [AX.Element] = []
        var prompts: [AX.Element] = []
        var sends: [AX.Element] = []
        var hasTemporaryChat = false
        var hasNewChat = false
        var hasShare = false
        let excludedRoles = Set(["AXRow", "AXTable", "AXList", "AXOutline"])
        while !queue.isEmpty {
            try checkCancellation(deadline: deadline)
            let (element, depth) = queue.removeLast()
            if visited.contains(element) { continue }
            guard visited.count < 250, depth <= 18 else { throw GeminiAppAutomationError.composerUnavailable }
            visited.append(element)
            let info = ax.metadata(element)
            try checkCancellation(deadline: deadline)
            if excludedRoles.contains(info.role) { continue }
            if info.role == "AXTextArea" {
                if let description = ax.promptDescription(element), ["问问 Gemini", "Ask Gemini"].contains(description) {
                    prompts.append(element)
                }
                try checkCancellation(deadline: deadline)
                continue
            }
            if info.role == "AXButton" {
                switch info.identifier {
                case "tempChat_button": hasTemporaryChat = true
                case "newChat_button": hasNewChat = true
                case "share_button": hasShare = true
                case "send_button": sends.append(element)
                default: break
                }
                continue
            }
            // Static text and history leaf values are never requested.
            if ["AXStaticText", "AXTextField", "AXImage", "AXMenuBar", "AXMenu"].contains(info.role) { continue }
            let children = ax.children(element)
            try checkCancellation(deadline: deadline)
            guard queue.count + visited.count + children.count <= 500 else { throw GeminiAppAutomationError.composerUnavailable }
            queue.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        guard !prompts.isEmpty else { throw GeminiAppAutomationError.composerNotReady }
        guard prompts.count == 1 else { throw GeminiAppAutomationError.composerUnavailable }
        try checkCancellation(deadline: deadline)
        try requireContext(window: window)
        try checkCancellation(deadline: deadline)
        let prompt = prompts[0]
        let promptText = ax.text(prompt)
        try checkCancellation(deadline: deadline)
        guard let text = promptText else { throw GeminiAppAutomationError.composerNotReady }
        let isNew = hasTemporaryChat && !hasNewChat && !hasShare
        if pendingNewLanding && isNew {
            boundWindow = window
            pendingNewLanding = false
        }
        let send = sends.count == 1 ? sends[0] : nil
        let canSend = send.map { ax.isEnabled($0) } ?? false
        try checkCancellation(deadline: deadline)
        return (GeminiAXSnapshot(text: text, isNewConversation: isNew, isFrontmost: true,
                                 canSend: canSend,
                                 submissionAccepted: submissionAttempted && text.isEmpty && hasShare && !isNew), prompt, send)
    }
}
