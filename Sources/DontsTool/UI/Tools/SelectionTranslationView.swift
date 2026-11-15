import DontsToolCore
import SwiftUI

struct SelectionTranslationView: View {
    @ObservedObject var controller: SelectionTranslationController
    @ObservedObject var session: ToolSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(controller.gestureVerificationShown ? "长按验证" : "划词翻译")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { controller.pinned.toggle() } label: {
                    Image(systemName: controller.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(controller.pinned ? ToolTheme.accent : ToolTheme.secondary)
                }.help(controller.pinned ? "取消固定" : "固定窗口，点击外部时保留")
                    .accessibilityLabel(controller.pinned ? "取消固定" : "固定窗口")
                Button { controller.dismiss() } label: { Image(systemName: "xmark") }
                    .help("关闭（Esc）").accessibilityLabel("关闭翻译卡片")
            }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 40)
                .background(ToolTheme.toolbar)
            Divider().overlay(ToolTheme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if controller.gestureVerificationShown {
                        Text("长按触发成功").font(.system(size: 22, weight: .semibold))
                        Text("已持续按住右键满 2 秒。")
                        Text("此模式只验证鼠标手势，不读取选中文字，也不发送翻译请求。")
                            .font(.system(size: 12)).foregroundStyle(ToolTheme.secondary)
                    } else {
                        Text("原文").font(.system(size: 10, weight: .medium)).foregroundStyle(ToolTheme.secondary)
                        Text(session.input).font(.system(size: 13)).lineLimit(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider().overlay(ToolTheme.border).padding(.vertical, 4)
                        Text(Locale.current.localizedString(forIdentifier: session.target) ?? session.target)
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(ToolTheme.secondary)
                        if controller.selectionReadInProgress {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取选中文字…") }
                                .font(.system(size: 12)).foregroundStyle(ToolTheme.secondary)
                        } else if let failure = controller.selectionFailure {
                            Text(failure).font(.system(size: 12)).foregroundStyle(.red)
                            Text("可点击“编辑原文”输入文字后翻译。")
                                .font(.system(size: 12)).foregroundStyle(ToolTheme.secondary)
                        } else if session.isRunning {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在翻译…") }
                                .font(.system(size: 12)).foregroundStyle(ToolTheme.secondary)
                        } else if !session.translationConfigured {
                            Text("请在翻译设置中填写大模型接口地址、模型和 API 密钥。")
                                .font(.system(size: 12)).foregroundStyle(ToolTheme.secondary)
                            Button("打开翻译设置") { controller.openSettings() }.controlSize(.small)
                        } else if let error = session.errorMessage {
                            Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                            Button("翻译设置") { controller.openSettings() }.controlSize(.small)
                        } else if session.isFresh {
                            Text(session.output).font(.system(size: 16, weight: .medium)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.background(ToolTheme.editor)
            Divider().overlay(ToolTheme.border)
            HStack(spacing: 8) {
                if !controller.gestureVerificationShown {
                    Button("编辑原文") { controller.editSource() }
                    Button("重试") { session.run() }.disabled(controller.selectionReadInProgress || session.input.isEmpty || session.isRunning || !session.translationConfigured)
                    Spacer()
                    Button(controller.copied ? "已复制" : "复制译文") { controller.copyTranslation() }
                        .disabled(!session.canCopy)
                        .tint(ToolTheme.accent)
                }
            }.controlSize(.small).padding(.horizontal, 12).padding(.top, 10)
            Text(controller.pinned ? "窗口已固定 · Esc 关闭" : "右键长按 2 秒 · Esc 关闭")
                .font(.system(size: 10)).foregroundStyle(ToolTheme.secondary)
                .padding(.top, 7).padding(.bottom, 10)
        }
        .foregroundStyle(ToolTheme.ink)
        .background(ToolTheme.shell)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ToolTheme.border, lineWidth: 1))
        .frame(width: 380, height: 330)
    }
}
