import AppKit
import DontsToolCore
import SwiftUI

struct QuickAIWindowView: View {
    @ObservedObject var session: QuickAISession
    let onOpenSettings: () -> Void
    let onNewWindow: () -> Void
    let onCloseWindow: () -> Void

    @State private var copiedMessageID: UUID?

    private static let bottomAnchorID = "quick-ai-bottom-anchor"

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Theme.separator.frame(height: 0.5)
            conversationBody
            Theme.separator.frame(height: 0.5)
            composerBar
        }
        .background(Theme.panelSolid)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text(session.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }

            if session.isConfigured {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.success)
                        .frame(width: 5, height: 5)
                    Text(session.activeModelDisplay)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.controlFill, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 0.5))
            } else {
                Button(action: onOpenSettings) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.warning)
                            .frame(width: 5, height: 5)
                        Text("未配置模型")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.warning)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.warning.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("打开「设置 → AI 与翻译」配置大模型")
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                toolbarIconButton(
                    symbol: "plus",
                    help: "新建 AI 对话窗口（⌘N）",
                    isActive: false,
                    action: onNewWindow
                )
                toolbarIconButton(
                    symbol: session.isPinned ? "pin.fill" : "pin",
                    help: session.isPinned ? "取消窗口置顶" : "置顶窗口",
                    isActive: session.isPinned
                ) {
                    session.isPinned.toggle()
                }
                toolbarIconButton(
                    symbol: "arrow.counterclockwise",
                    help: "清空当前对话",
                    isActive: false
                ) {
                    session.resetConversation()
                }
                .disabled(session.messages.isEmpty && !session.isStreaming)
                .opacity((session.messages.isEmpty && !session.isStreaming) ? 0.45 : 1)

                toolbarIconButton(
                    symbol: "gearshape",
                    help: "打开「AI 与翻译」设置",
                    isActive: false,
                    action: onOpenSettings
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.headerBase)
    }

    private func toolbarIconButton(
        symbol: String,
        help: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : Theme.secondary)
                .frame(width: 26, height: 24)
                .background(
                    isActive ? Theme.accentFill : Theme.controlFill,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? Theme.accentBorder : Theme.controlBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Conversation Body

    @ViewBuilder
    private var conversationBody: some View {
        if !session.isConfigured && session.messages.isEmpty {
            unconfiguredPlaceholder
        } else if session.messages.isEmpty {
            emptyConversationView
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !session.isConfigured {
                            unconfiguredInlineBanner
                        }

                        if let systemPrompt = session.systemPrompt, !systemPrompt.isEmpty {
                            systemPromptBanner(systemPrompt)
                        }

                        ForEach(session.messages) { message in
                            if message.role == .user {
                                userMessageCard(message)
                            } else {
                                assistantMessageCard(
                                    message,
                                    isLastAssistant: message.id == lastAssistantMessageID
                                )
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: session.messages.last?.content.count ?? 0) { _, _ in
                    if session.isStreaming {
                        scrollToBottom(proxy)
                    }
                }
            }
        }
    }

    private var lastAssistantMessageID: UUID? {
        session.messages.last(where: { $0.role == .assistant })?.id
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.14)) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private var unconfiguredPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(Theme.accentBorder, lineWidth: 0.6)
                    )

                Text("尚未配置大模型服务")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)

                Text("请在「设置 → AI 与翻译」填写接口地址、模型名称和 API 密钥。\n支持 OpenAI Responses、Gemini 原生与 OpenAI Chat Completions 三种接口格式，与翻译及划词翻译共用。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)

                Button(action: onOpenSettings) {
                    Text("打开「AI 与翻译」设置")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(24)
            .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.glassCardBorder, lineWidth: 0.6)
            )
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyConversationView: some View {
        VStack(spacing: 10) {
            Spacer()
            if let systemPrompt = session.systemPrompt, !systemPrompt.isEmpty {
                systemPromptBanner(systemPrompt)
                    .frame(maxWidth: 480)
            }
            Text("输入问题后按 ↵ 发送，⇧↵ 换行")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            Text("当前使用 \(session.activeModelDisplay)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unconfiguredInlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)
            Text("尚未完成大模型服务配置，请先在「设置 → AI 与翻译」填写接口地址、模型和 API 密钥。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsButton(title: "前往设置", action: onOpenSettings)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.warning.opacity(0.32), lineWidth: 0.6)
        )
    }

    private func systemPromptBanner(_ prompt: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 2)
            Text("系统提示词：\(prompt)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .help(prompt)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.controlFill.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
        )
    }

    private func userMessageCard(_ message: QuickAIMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("你")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                copyButton(for: message, label: "复制")
            }
            Text(message.content)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
        )
    }

    private func assistantMessageCard(_ message: QuickAIMessage, isLastAssistant: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text("AI")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                    Text("生成中…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
            }

            if !message.content.isEmpty {
                QuickAIMarkdownView(text: message.content)
            } else if message.isStreaming {
                Text("正在等待模型响应…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiary)
            }

            if let errorMessage = message.errorMessage, !errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                        .padding(.top, 1)
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isConfigurationError(errorMessage) {
                        SettingsButton(title: "前往设置", action: onOpenSettings)
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.red.opacity(0.24), lineWidth: 0.6)
                )
            }

            if !message.isStreaming {
                HStack(spacing: 8) {
                    if !message.content.isEmpty {
                        copyButton(for: message, label: "复制回答")
                    }
                    if isLastAssistant && session.canRegenerate {
                        Button {
                            session.regenerateLast()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10.5, weight: .medium))
                                Text("重新生成")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
        .padding(13)
        .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.glassCardBorder, lineWidth: 0.6)
        )
    }

    private func copyButton(for message: QuickAIMessage, label: String) -> some View {
        let isCopied = copiedMessageID == message.id
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
            copiedMessageID = message.id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                if copiedMessageID == message.id {
                    copiedMessageID = nil
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                Text(isCopied ? "已复制" : label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isCopied ? Theme.success : Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func isConfigurationError(_ message: String) -> Bool {
        message.contains("设置") || message.contains("未配置") || message.contains("密钥")
    }

    // MARK: - Composer Bar

    private var composerBar: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if session.draftPrompt.isEmpty {
                        Text("继续提问…（↵ 发送，⇧↵ 换行）")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                    QuickAIComposerView(
                        text: $session.draftPrompt,
                        placeholder: "继续提问…",
                        isDisabled: false,
                        onSubmit: {
                            guard !session.isStreaming else { return }
                            session.sendDraft()
                        },
                        onEscape: {
                            if session.isStreaming {
                                session.stopStreaming()
                            } else {
                                onCloseWindow()
                            }
                        },
                        onNewWindow: onNewWindow
                    )
                    .frame(minHeight: 36, maxHeight: 110)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Theme.controlBorder, lineWidth: 0.6)
                )

                if session.isStreaming {
                    Button {
                        session.stopStreaming()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10.5))
                            Text("停止生成")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Theme.controlBorder, lineWidth: 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("停止流式生成（Esc）")
                } else {
                    let canSend = !session.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        session.sendDraft()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 34, height: 34)
                            .background(
                                canSend ? Theme.accent : Theme.accent.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("发送提问（↵）")
                }
            }

            HStack(spacing: 6) {
                Text("DontsTool AI")
                    .font(Theme.footerFont.weight(.medium))
                    .foregroundStyle(Theme.tertiary)
                Spacer()
                composerHint(key: "↵", label: "发送")
                Text("·").font(Theme.footerFont).foregroundStyle(Theme.tertiary)
                composerHint(key: "⇧↵", label: "换行")
                Text("·").font(Theme.footerFont).foregroundStyle(Theme.tertiary)
                composerHint(key: "esc", label: session.isStreaming ? "停止" : "关闭")
                Text("·").font(Theme.footerFont).foregroundStyle(Theme.tertiary)
                composerHint(key: "⌘N", label: "新窗口")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.footerBase)
    }

    private func composerHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(text: key)
            Text(label)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.tertiary)
        }
    }
}
