import AppKit
import DontsToolCore
import SwiftUI

@MainActor
final class SettingsNavigationState: ObservableObject {
    @Published var tab: SettingsRootView.Tab = .general
}

/// 设置窗口内容：172pt 侧边栏 + 分组表单（design/05-settings.html）。
struct SettingsRootView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "通用"
        case search = "搜索"
        case websites = "网址快捷入口"
        case tools = "工具"
        case translation = "翻译"
        case knowledge = "知识库"
        case index = "索引"
        case about = "关于"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .search: "magnifyingglass"
            case .websites: "link"
            case .tools: "wrench.and.screwdriver"
            case .translation: "character.bubble"
            case .knowledge: "books.vertical"
            case .index: "folder"
            case .about: "info.circle"
            }
        }
    }

    @ObservedObject var settings: SettingsStore
    @ObservedObject var websites: WebsiteShortcutStore
    @ObservedObject var login: LoginItemManager
    let secrets: SecretStoring
    @ObservedObject var appIndex: AppIndex
    @ObservedObject var selectionTranslation: SelectionTranslationController
    @ObservedObject var navigation: SettingsNavigationState
    let onRescan: () -> Void
    let onHotKeyRecordingChanged: (Bool) -> Void

    private var tab: Tab { navigation.tab }
    @State private var apiKey: String = ""
    @State private var apiKeyStatus: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.separator)
            content
        }
        .frame(width: Metrics.settingsSize.width, height: Metrics.settingsSize.height)
        .background(Theme.panelBase.opacity(0.5))
        .onAppear {
            apiKey = secrets.secret(for: SecretAccount.translationAPIKey) ?? ""
        }
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("DT")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24, height: 24)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.accentBorder, lineWidth: 1)
                    )
                Text("DontsTool")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .padding(.bottom, 8)

            ForEach(Tab.allCases) { entry in
                sidebarItem(entry)
            }
            Spacer()
            HStack(spacing: 6) {
                KeyCap(text: HotKeyFormatter.displayString(for: settings.hotKey))
                Text("呼出启动器")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
        }
        .padding(.top, 8)
        .frame(width: Metrics.settingsSidebarWidth)
        .background(Theme.headerBase)
    }

    private func sidebarItem(_ entry: Tab) -> some View {
        Button {
            navigation.tab = entry
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(entry.rawValue)
                    .font(.system(size: 13, weight: tab == entry ? .medium : .regular))
                Spacer()
            }
            .foregroundStyle(tab == entry ? Theme.onAccent : Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                tab == entry ? Theme.accent : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 内容

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tab.rawValue)
                    .font(Theme.settingsTitleFont)
                    .foregroundStyle(Theme.ink)
                switch tab {
                case .general: generalTab
                case .search: searchTab
                case .websites: WebsiteShortcutsSettingsView(store: websites)
                case .tools: toolsTab
                case .translation: translationTab
                case .knowledge: knowledgeTab
                case .index: indexTab
                case .about: aboutTab
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.footerBase.opacity(0.4))
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "启动与快捷键") {
                SettingsRow(title: "呼出快捷键", subtitle: "在任意应用中呼出；也可双击 ⌘/⌥/⌃/⇧") {
                    HotKeyRecorder(
                        display: HotKeyFormatter.displayString(for: settings.hotKey)
                    ) { configuration in
                        settings.setHotKey(configuration)
                    } onRecordingChanged: { isRecording in
                        onHotKeyRecordingChanged(isRecording)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "登录时启动", subtitle: "在登录 Mac 后自动运行") {
                    Toggle("", isOn: Binding(
                        get: { login.isEnabled },
                        set: { login.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "外观", subtitle: "跟随 macOS 系统外观") {
                    SettingsBadge(text: "跟随系统")
                }
            }
            SettingsGroup(caption: "使用说明") {
                guideRow("选择结果", keys: ["↑", "↓"])
                SettingsDivider()
                guideRow("执行操作", keys: ["↵"])
                SettingsDivider()
                guideRow("执行次操作", keys: ["⌘", "↵"])
                SettingsDivider()
                guideRow("关闭面板", keys: ["esc"])
            }
            privacyNote
        }
    }

    private var searchTab: some View {
        SettingsGroup(caption: "搜索行为") {
            SettingsRow(title: "默认搜索引擎", subtitle: "全局查询无本地结果时的网页回退") {
                Picker("", selection: Binding(
                    get: { settings.defaultSearchEngine },
                    set: { settings.setDefaultSearchEngine($0) }
                )) {
                    ForEach(SettingsStore.SearchEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            SettingsDivider()
            SettingsRow(title: "文件搜索", subtitle: "使用 Spotlight 索引按文件名搜索") {
                Toggle("", isOn: Binding(
                    get: { settings.fileSearchEnabled },
                    set: { settings.setFileSearchEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    private var toolsTab: some View {
        SettingsGroup(caption: "内置工具") {
            ForEach(Array(providerEntries.enumerated()), id: \.offset) { offset, entry in
                if offset > 0 { SettingsDivider() }
                SettingsRow(title: entry.name, subtitle: entry.hint) {
                    Toggle("", isOn: Binding(
                        get: { settings.isProviderEnabled(entry.id) },
                        set: { settings.setProviderEnabled(entry.id, to: $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
        }
    }

    private var knowledgeTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "DontsKb 服务") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("服务地址").font(.system(size: 13, weight: .medium))
                    TextField("https://你的知识库域名", text: Binding(
                        get: { settings.knowledgeBaseURL }, set: { settings.setKnowledgeBaseURL($0) }
                    )).textFieldStyle(.roundedBorder)
                    if !settings.knowledgeBaseURL.isEmpty, (try? KnowledgeOrigin(settings.knowledgeBaseURL)) == nil {
                        Text("请输入 HTTPS 来源地址，不带路径、账号或查询参数；本地开发支持 HTTP localhost。")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text("在知识库窗口内登录。登录状态由知识库页面管理，DontsTool 不读取或保存登录凭据。")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }.padding(12)
            }
            SettingsGroup(caption: "启动器入口") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("kb 关键词：搜索文档并在独立窗口编辑")
                    Text("collect 内容：打开快速收集，确认后保存")
                    Text("inbox：打开收集箱")
                    Text("需要知识库 Web 服务包含 /tool 插件页面。窗口可置顶，文章内容与保存状态由知识库同步。")
                        .foregroundStyle(Theme.secondary)
                }.font(.system(size: 12)).padding(12)
            }
        }
    }

    private var translationTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "划词翻译") {
                SettingsRow(title: "右键长按翻译", subtitle: "选中文字后，右键或双指按住触控板 0.5 秒") {
                    Toggle("", isOn: Binding(get: { settings.selectionTranslationEnabled },
                        set: { settings.setSelectionTranslationEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectionTranslation.status).font(.system(size: 12))
                    Text("通过辅助功能读取其他应用选中的文字，触发后才发送到你配置的翻译 API。不会自动复制，也不读取剪贴板。")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    Text("短按在松开时显示原有右键菜单；移动会取消长按。不支持取词的应用仍可手动复制到翻译窗口。")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    HStack {
                        if !selectionTranslation.accessibilityGranted {
                            SettingsButton(title: "授权辅助功能") { selectionTranslation.requestAccessibility() }
                        }
                        SettingsButton(title: "重新检查") { selectionTranslation.refresh() }
                    }
                }.padding(12)
            }
            SettingsGroup(caption: "翻译目标") {
                SettingsRow(title: "目标语言", subtitle: "tr 关键词翻译的目标语言") {
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
            SettingsGroup(caption: "翻译 API（OpenAI Responses 兼容）") {
                SettingsRow(title: "接口地址", subtitle: "例如 https://api.deepseek.com/v1") {
                    SettingsTextField(
                        placeholder: "https://api.deepseek.com/v1",
                        text: Binding(
                            get: { settings.translationAPIBaseURL },
                            set: { settings.setTranslationAPIBaseURL($0) }
                        )
                    )
                }
                SettingsDivider()
                SettingsRow(title: "模型", subtitle: "例如 deepseek-chat") {
                    SettingsTextField(
                        placeholder: "deepseek-chat",
                        text: Binding(
                            get: { settings.translationAPIModel },
                            set: { settings.setTranslationAPIModel($0) }
                        )
                    )
                }
                SettingsDivider()
                SettingsRow(title: "API 密钥", subtitle: apiKeyStatus ?? "保存在本机钥匙串，不会上传") {
                    HStack(spacing: 8) {
                        SettingsTextField(placeholder: "sk-…", text: $apiKey, isSecure: true) {
                            saveAPIKey()
                        }
                        SettingsButton(title: "保存") { saveAPIKey() }
                    }
                }
            }
        }
    }

    private var indexTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "应用索引") {
                SettingsRow(
                    title: "已索引 \(appIndex.apps.count) 个应用",
                    subtitle: appIndex.lastError ?? "应用列表保存在本机，安装新应用后可手动更新"
                ) {
                    HStack(spacing: 8) {
                        KeyCap(text: "⌘ R")
                        SettingsButton(title: "重新扫描", action: onRescan)
                    }
                }
            }
            SettingsGroup(caption: "文件搜索") {
                SettingsRow(title: "启用文件搜索", subtitle: "使用 Spotlight 索引按文件名搜索") {
                    Toggle("", isOn: Binding(
                        get: { settings.fileSearchEnabled },
                        set: { settings.setFileSearchEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "关于") {
                SettingsRow(title: "DontsTool", subtitle: "个人自用的原生 macOS 效率启动器") {
                    SettingsBadge(text: "V1")
                }
                SettingsDivider()
                SettingsRow(title: "版本", subtitle: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") {
                    SettingsBadge(text: "ad-hoc 签名")
                }
            }
            privacyNote
        }
    }

    // MARK: 小组件

    private func guideRow(_ title: String, keys: [String]) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { KeyCap(text: $0) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var privacyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 11))
            Text("设置与使用记录仅保存在本机")
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var providerEntries: [(id: String, name: String, hint: String)] {
        [
            (ProviderID.app.rawValue, "应用启动", "搜索并打开本机应用"),
            (ProviderID.file.rawValue, "文件搜索", "按文件名搜索 Spotlight 索引"),
            (ProviderID.text.rawValue, "文本工具", "json、base64、url、时间戳、哈希、UUID"),
            (ProviderID.web.rawValue, "网页搜索", "关键词或默认引擎回退"),
            (ProviderID.translation.rawValue, "翻译", "tr 关键词调用配置的翻译 API"),
            (ProviderID.knowledge.rawValue, "知识库", "搜索、编辑和收集 DontsKb 内容")
        ]
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
