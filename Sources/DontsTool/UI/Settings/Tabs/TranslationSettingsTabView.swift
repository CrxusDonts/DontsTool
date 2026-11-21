import DontsToolCore
import SwiftUI

struct TranslationSettingsTabView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var selectionTranslation: SelectionTranslationController
    let secrets: SecretStoring
    let onOpenAIModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "翻译设置") {
                SettingsRow(title: "当前模型", subtitle: activeModelSubtitle) {
                    SettingsButton(title: "配置模型…", action: onOpenAIModels)
                }
                SettingsDivider()
                SettingsRow(title: "目标语言", subtitle: "翻译窗口与划词卡片的目标语言") {
                    Picker("", selection: Binding(
                        get: { settings.translationTarget },
                        set: { settings.setTranslationTarget($0) }
                    )) {
                        ForEach(targetLanguages, id: \.id) { entry in
                            Text(entry.name).tag(entry.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            SettingsGroup(caption: "划词翻译") {
                SettingsRow(title: "右键长按翻译", subtitle: "选中文字后，双指停留在妙控板上，或按住鼠标右键") {
                    Toggle("", isOn: Binding(get: { settings.selectionTranslationEnabled },
                        set: { settings.setSelectionTranslationEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "唤起时间", subtitle: "双指停留和鼠标右键共用，修改后立即生效") {
                    Picker("唤起时间", selection: Binding(get: { settings.selectionHoldDelay },
                        set: { settings.setSelectionHoldDelay($0) })) {
                        ForEach(SelectionHoldDelay.allCases) { delay in Text(delay.label).tag(delay) }
                    }.labelsHidden().frame(width: 160)
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectionTranslation.status).font(.system(size: 12))
                    Text("最近操作：\(selectionTranslation.lastGestureDiagnostic)")
                        .font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    Text("长按触发后，向源应用发送复制指令，读取本次复制的文字交给你配置的模型服务翻译。不主动清空剪贴板，复制的文字会保留在剪贴板。")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    Text("短按在松开时显示原有右键菜单；移动或滚动会取消长按。未返回新复制内容时不会使用已有剪贴板文字。")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    HStack {
                        if !selectionTranslation.accessibilityGranted {
                            SettingsButton(title: "授权辅助功能") { selectionTranslation.requestAccessibility() }
                        }
                        SettingsButton(title: "重新检查") { selectionTranslation.refresh() }
                    }
                }.padding(12)
            }
        }
    }

    private var activeModelSubtitle: String {
        let config = settings.resolvedAIConfiguration(for: .translation)
        let hasKey = settings.apiKey(for: config, secrets: secrets) != nil
        guard config.isEndpointComplete, hasKey else {
            return "尚未配置可用的模型服务"
        }
        return config.displaySummary
    }

    private var targetLanguages: [(id: String, name: String)] {
        [
            ("zh-Hans", "简体中文"),
            ("zh-Hant", "繁体中文"),
            ("en", "英语"),
            ("ja", "日语"),
            ("ko", "韩语"),
            ("fr", "法语"),
            ("de", "德语"),
            ("es", "西班牙语"),
            ("ru", "俄语")
        ]
    }
}
