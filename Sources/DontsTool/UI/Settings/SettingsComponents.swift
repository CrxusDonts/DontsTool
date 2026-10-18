import DontsToolCore
import SwiftUI

/// 设置分组：标题 + 圆角卡片行。
struct SettingsGroup<Content: View>: View {
    let caption: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(Theme.sectionCaptionFont)
                .foregroundStyle(Theme.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                content
            }
            .background(Theme.panelBase.opacity(0.6), in: RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            )
        }
    }
}

/// 设置行：左侧标题/说明，右侧控件。
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.settingTitleFont)
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.settingSubtitleFont)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// 行与行之间的细分隔线。
struct SettingsDivider: View {
    var body: some View {
        Theme.separator.frame(height: 1)
    }
}

/// 只读状态徽章：跟随系统、就绪等。
struct SettingsBadge: View {
    let text: String
    var tone: Tone = .neutral

    enum Tone {
        case neutral
        case success
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone == .success ? Theme.success : Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (tone == .success ? Theme.success : Theme.secondary).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}

/// 设置页文本输入框。
struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.controlBorder, lineWidth: 1)
        )
        .frame(width: 260)
        .onSubmit { onSubmit?() }
    }
}

/// 设置页按钮。
struct SettingsButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.controlBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
