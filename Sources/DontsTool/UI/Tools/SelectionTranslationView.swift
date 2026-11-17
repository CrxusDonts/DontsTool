import DontsToolCore
import SwiftUI

struct SelectionTranslationView: View {
    @ObservedObject var controller: SelectionTranslationController
    @ObservedObject var session: ToolSession
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var targetLabel: String {
        Locale.current.localizedString(forIdentifier: session.target) ?? session.target
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(controller.gestureVerificationShown ? "长按验证" : "划词翻译")
                    .font(.system(size: 12, weight: .semibold))
                if !controller.gestureVerificationShown {
                    Text(targetLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Button { controller.pinned.toggle() } label: {
                    Image(systemName: controller.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11.5))
                        .foregroundStyle(controller.pinned ? Theme.accent : Theme.secondary)
                        .frame(width: 22, height: 22)
                        .background(controller.pinned ? Theme.accentFill : Color.clear, in: Circle())
                }
                .help(controller.pinned ? "取消固定" : "固定窗口，点击外部时保留")
                .accessibilityLabel(controller.pinned ? "取消固定" : "固定窗口")

                Button { controller.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22)
                }
                .help("关闭（Esc）")
                .accessibilityLabel("关闭翻译卡片")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Theme.headerBase)

            Theme.separator.frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if controller.gestureVerificationShown {
                        Text("长按触发成功").font(.system(size: 19, weight: .semibold))
                        Text("已持续保持满 \(controller.holdDelayLabel)。").font(.system(size: 13))
                        Text("此模式只验证鼠标手势，不读取选中文字，也不发送翻译请求。")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    } else {
                        Text("原文")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                        Text(session.input)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Theme.separator.frame(height: 0.5).padding(.vertical, 4)

                        Text(targetLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)

                        if session.isRunning {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在翻译…") }
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        } else if !session.translationConfigured {
                            Text("请在翻译设置中填写大模型接口地址、模型和 API 密钥。")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            Button("打开翻译设置") { controller.openSettings() }.controlSize(.small)
                        } else if let error = session.errorMessage {
                            Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                            Button("翻译设置") { controller.openSettings() }.controlSize(.small)
                        } else if session.isFresh {
                            Text(session.output)
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Theme.separator.frame(height: 0.5)

            VStack(spacing: 5) {
                if !controller.gestureVerificationShown {
                    HStack(spacing: 8) {
                        Button("编辑原文") { controller.editSource() }
                        Button("重试") { session.run() }
                            .disabled(controller.selectionReadInProgress || session.input.isEmpty || session.isRunning || !session.translationConfigured)
                        Spacer()
                        Button(controller.copied ? "已复制" : "复制译文") { controller.copyTranslation() }
                            .disabled(!session.canCopy)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                    .controlSize(.small)
                }
                Text(controller.pinned ? "窗口已固定 · Esc 关闭" : "双指 / 右键保持 \(controller.holdDelayLabel) · Esc 关闭")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.footerBase)
        }
        .foregroundStyle(Theme.ink)
        .background {
            ZStack {
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)
                }
                RoundedRectangle(cornerRadius: 14).fill(reduceTransparency ? Theme.panelSolid : Theme.panelBase)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.75)
        )
        .frame(width: 360, height: 310)
    }
}
