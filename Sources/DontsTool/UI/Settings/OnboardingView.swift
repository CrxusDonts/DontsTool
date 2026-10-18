import DontsToolCore
import SwiftUI

/// 首次运行引导：说明热键、菜单栏与权限边界（spec 6.5）。
struct OnboardingView: View {
    let hotKeyDisplay: String
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("DT")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.accentBorder, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 DontsTool")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("个人自用的原生 macOS 效率启动器")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
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
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panelBase.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
