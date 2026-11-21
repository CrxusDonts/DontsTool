import DontsToolCore
import SwiftUI

struct TranslationSettingsTabView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var selectionTranslation: SelectionTranslationController
    let secrets: SecretStoring
    let onOpenPlugins: () -> Void

    @State private var apiKey: String = ""
    @State private var apiKeyStatus: String?
    @State private var apiKeyLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "大模型服务（AI 与翻译共用）") {
                SettingsRow(title: "接口格式", subtitle: "选择与你的大模型服务匹配的 REST 接口格式") {
                    Picker("接口格式", selection: Binding(
                        get: { settings.aiAPIFormat },
                        set: { settings.setAIAPIFormat($0) }
                    )) {
                        ForEach(AIAPIFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 210)
                }
                SettingsDivider()
                SettingsRow(title: "接口地址", subtitle: baseURLSubtitle) {
                    SettingsTextField(
                        placeholder: settings.aiAPIFormat.defaultBaseURLPlaceholder,
                        text: Binding(
                            get: { settings.translationAPIBaseURL },
                            set: { settings.setTranslationAPIBaseURL($0) }
                        )
                    )
                }
                SettingsDivider()
                SettingsRow(title: "模型", subtitle: "必填，对应服务支持的模型名称") {
                    SettingsTextField(
                        placeholder: settings.aiAPIFormat.defaultModelPlaceholder,
                        text: Binding(
                            get: { settings.translationAPIModel },
                            set: { settings.setTranslationAPIModel($0) }
                        )
                    )
                }
                SettingsDivider()
                SettingsRow(title: "API 密钥", subtitle: apiKeyStatus ?? "必填，保存在本机钥匙串，仅用于向该服务认证") {
                    HStack(spacing: 8) {
                        SettingsTextField(placeholder: apiKeyPlaceholder, text: $apiKey, isSecure: true) {
                            saveAPIKey()
                        }
                        SettingsButton(title: "保存") { saveAPIKey() }
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "AI 快问插件共用此配置",
                    subtitle: "翻译窗口、划词翻译与官方「AI 快问」插件共用上方大模型配置，密钥不会交给插件进程"
                ) {
                    SettingsButton(title: "前往插件") {
                        onOpenPlugins()
                    }
                }
            }

            SettingsGroup(caption: "翻译目标") {
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
                    Text("长按触发后，向源应用发送复制指令，读取本次复制的文字交给你配置的大模型服务翻译。不主动清空剪贴板，复制的文字会保留在剪贴板。")
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
        .onAppear {
            guard !apiKeyLoaded else { return }
            apiKeyLoaded = true
            apiKey = secrets.secret(for: SecretAccount.translationAPIKey) ?? ""
        }
    }

    private var baseURLSubtitle: String {
        switch settings.aiAPIFormat {
        case .openAIResponses:
            "必填，自动补全 /responses 路径，使用 Bearer 请求头鉴权"
        case .gemini:
            "必填，自动补全 /v1beta；使用 x-goog-api-key 请求头鉴权，密钥不写入 URL"
        case .openAIChatCompletions:
            "必填，自动补全 /chat/completions 路径，使用 Bearer 请求头鉴权"
        }
    }

    private var apiKeyPlaceholder: String {
        switch settings.aiAPIFormat {
        case .gemini: "AIza…"
        case .openAIResponses, .openAIChatCompletions: "sk-…"
        }
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

    private func saveAPIKey() {
        secrets.setSecret(apiKey.isEmpty ? nil : apiKey, for: SecretAccount.translationAPIKey)
        apiKeyStatus = apiKey.isEmpty ? "已清除密钥" : "密钥已保存到钥匙串"
    }
}
