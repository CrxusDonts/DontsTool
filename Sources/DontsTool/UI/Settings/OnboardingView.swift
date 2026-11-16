import DontsToolCore
import SwiftUI

/// 首次运行引导：Liquid Glass 卡片说明热键、菜单栏与权限边界。
struct OnboardingView: View {
    let hotKeyDisplay: String
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("DT")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.accentBorder, lineWidth: 0.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 DontsTool")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("原生 macOS 效率启动器")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                bullet("按 \(hotKeyDisplay) 呼出或隐藏启动器面板。")
                bullet("菜单栏图标可打开面板、设置与重新扫描应用。")
                bullet("文件搜索使用本机 Spotlight 索引，不会上传内容。")
                bullet("翻译需要在设置中配置 API 地址、模型与密钥。")
            }

            HStack(spacing: 10) {
                SettingsButton(title: "打开设置", action: onOpenSettings)
                Spacer()
                Button(action: onDismiss) {
                    Text("开始使用")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 410)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14).fill(Theme.panelBase)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
        )
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
