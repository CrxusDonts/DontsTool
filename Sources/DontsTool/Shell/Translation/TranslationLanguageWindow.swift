import AppKit
import Combine
import SwiftUI
@preconcurrency import Translation

@MainActor
final class TranslationLanguageWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var preparation: TranslationLanguagePreparation?

    func show(target: String) {
        if let window, preparation?.target == target, window.contentView != nil {
            NSApp.activate(); window.makeKeyAndOrderFront(nil); return
        }
        preparation?.cancel()
        window?.contentView = nil
        let preparation = TranslationLanguagePreparation(target: target)
        self.preparation = preparation
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "系统翻译语言包"
        window.delegate = self
        window.contentView = NSHostingView(rootView: TranslationLanguagePreparationView(model: preparation) { [weak self] in
            self?.window?.close()
        })
        if self.window == nil { window.center() }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        preparation?.cancel()
        preparation = nil
        window?.contentView = nil
    }
}

@MainActor
protocol TranslationLanguagePreparingSession: AnyObject {
    func prepareTranslation() async throws
    var isReady: Bool { get async }
    func cancel()
}

@MainActor
private final class AppleLanguagePreparingSession: TranslationLanguagePreparingSession {
    private let session: TranslationSession
    init(_ session: TranslationSession) { self.session = session }
    func prepareTranslation() async throws { try await session.prepareTranslation() }
    var isReady: Bool { get async { await session.isReady } }
    func cancel() { session.cancel() }
}

@MainActor
final class TranslationLanguagePreparation: ObservableObject {
    let target: String
    let source: String
    struct Request {
        let id: UUID
        var configuration: TranslationSession.Configuration
    }
    @Published private(set) var request: Request?
    var configuration: TranslationSession.Configuration? { request?.configuration }
    @Published private(set) var isPreparing = false
    @Published private(set) var isReady = false
    @Published private(set) var status = "点击准备语言包，由 macOS 确认并下载所需语言。"
    private var session: (any TranslationLanguagePreparingSession)?

    init(target: String) {
        self.target = target
        source = Locale.Language(identifier: target).languageCode?.identifier == "en" ? "zh-Hans" : "en"
    }

    func prepare() {
        guard !isPreparing else { return }
        isPreparing = true
        isReady = false
        status = "正在准备语言包，请在 macOS 提示中确认下载…"
        let nextConfiguration: TranslationSession.Configuration
        if var existing = configuration {
            existing.invalidate()
            nextConfiguration = existing
        } else if #available(macOS 26.4, *) {
            nextConfiguration = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                target: Locale.Language(identifier: target), preferredStrategy: .lowLatency)
        } else {
            nextConfiguration = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                target: Locale.Language(identifier: target))
        }
        request = Request(id: UUID(), configuration: nextConfiguration)
    }

    func cancel() {
        request = nil
        session?.cancel()
        session = nil
        isPreparing = false
        isReady = false
        status = "已取消，可重新准备语言包。"
    }

    func run(session: any TranslationLanguagePreparingSession, requestID: UUID) async {
        guard request?.id == requestID else {
            session.cancel()
            return
        }
        let id = requestID
        self.session = session
        do {
            try Task.checkCancellation()
            try await session.prepareTranslation()
            try Task.checkCancellation()
            let ready = await session.isReady
            guard request?.id == id else { return }
            isReady = ready
            status = ready ? "语言包已就绪，可以关闭窗口并重新划词翻译。" : "语言包尚未就绪，请重试。"
        } catch {
            guard request?.id == id else { return }
            status = Task.isCancelled || error is CancellationError
                ? "已取消，可重新准备语言包。" : "未能准备语言包，请检查网络后重试。"
        }
        guard request?.id == id else { return }
        self.session = nil
        isPreparing = false
    }
}

private struct TranslationLanguagePreparationView: View {
    @ObservedObject var model: TranslationLanguagePreparation
    let close: () -> Void

    var body: some View {
        let request = model.request
        VStack(alignment: .leading, spacing: 16) {
            Label("系统翻译语言包", systemImage: "character.bubble")
                .font(.title3.weight(.semibold))
            Text("\(languageName(model.source)) → \(languageName(model.target))")
                .font(.headline)
            Text("语言包下载需要网络和系统确认。准备完成后，翻译在本机进行，无需 API 密钥。")
                .font(.callout).foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                if model.isPreparing { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                if model.isPreparing { Button("取消准备") { model.cancel() } }
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
                Button(model.isReady ? "重新检查" : "准备语言包") { model.prepare() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(model.isPreparing)
            }
        }
        .padding(24)
        .frame(width: 460, height: 280)
        .foregroundStyle(Theme.ink)
        .background(Theme.panelSolid)
        .tint(Theme.accent)
        .translationTask(request?.configuration) { session in
            guard let request else { return }
            await model.run(session: AppleLanguagePreparingSession(session), requestID: request.id)
        }
        .id(request?.id)
    }

    private func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
