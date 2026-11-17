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

    @ObservedObject var updates: AppUpdateController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var websites: WebsiteShortcutStore
    @ObservedObject var searchEngines: SearchEngineStore
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
    @State private var apiKeyLoaded = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Theme.separator.frame(width: 0.5)
            content
        }
        .frame(width: Metrics.settingsSize.width, height: Metrics.settingsSize.height)
        .background(.ultraThinMaterial)
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
            .foregroundStyle(tab == entry ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                tab == entry ? Theme.selection : .clear,
                in: RoundedRectangle(cornerRadius: 7)
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
                guideRow("查看全部操作", keys: ["⌘", "K"])
                SettingsDivider()
                guideRow("关闭面板", keys: ["esc"])
            }
            privacyNote
        }
    }

    private var searchTab: some View {
      VStack(alignment: .leading, spacing: 16) {
        SearchEnginesSettingsView(store: searchEngines, websites: websites)
        SettingsGroup(caption: "搜索行为") {
            SettingsRow(title: "按需文件搜索", subtitle: "仅输入 file 加文件名时查询 Spotlight，普通搜索不查文件") {
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

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
          SettingsGroup(caption: "内置工具") {
            ForEach(Array(providerEntries.enumerated()), id: \.offset) { offset, entry in
                if offset > 0 { SettingsDivider() }
                SettingsRow(title: entry.name, subtitle: entry.id == ProviderID.gemini.rawValue && !geminiInstalled
                            ? (appIndex.isScanning ? "正在检测 Gemini Mac 版…" : "未安装 Gemini Mac 版，安装后可启用") : entry.hint) {
                    Toggle("", isOn: Binding(
                        get: { settings.isProviderEnabled(entry.id) && (entry.id != ProviderID.gemini.rawValue || geminiInstalled) },
                        set: { settings.setProviderEnabled(entry.id, to: $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(entry.id == ProviderID.gemini.rawValue && !geminiInstalled)
                }
            }
          }
          SettingsGroup(caption: "Gemini 自动提问") {
            SettingsRow(title: "Gemini Mac 版", subtitle: geminiInstalled ? "已在本机应用索引中找到 Gemini"
                        : (appIndex.isScanning ? "正在检测本机应用…" : "安装 Gemini Mac 版后，此功能才可使用")) {
                SettingsBadge(text: geminiInstalled ? "已安装" : (appIndex.isScanning ? "检测中" : "未安装"))
            }
            if geminiInstalled {
                SettingsDivider()
                SettingsRow(title: selectionTranslation.accessibilityGranted ? "辅助功能已授权" : "自动输入需要辅助功能授权",
                            subtitle: "只在执行 gm 问题时操作 Gemini；仅打开应用无需此权限") {
                    if !selectionTranslation.accessibilityGranted {
                        SettingsButton(title: "授权辅助功能") { selectionTranslation.requestAccessibility() }
                    }
                }
            }
            Text("如果 Gemini 已有未发送草稿，会停止自动提问并保留草稿。问题仅在回车执行后交给 Gemini，不进入剪贴板或日志。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(12)
          }
        }
    }

    private var knowledgeTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "知识库功能") {
                SettingsRow(title: "启用知识库", subtitle: "控制知识库、收集箱和快速收集入口；关闭后停止后台搜索，已打开窗口仍可保存") {
                    Toggle("启用知识库", isOn: Binding(
                        get: { settings.isProviderEnabled(ProviderID.knowledge.rawValue) },
                        set: { settings.setProviderEnabled(ProviderID.knowledge.rawValue, to: $0) }
                    )).toggleStyle(.switch).labelsHidden()
                }
            }
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
            .disabled(!settings.isProviderEnabled(ProviderID.knowledge.rawValue))
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
                    Text("长按触发后，向源应用发送复制指令，读取本次复制的文字交给你配置的大模型翻译服务。不主动清空剪贴板，复制的文字会保留在剪贴板。")
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
            SettingsGroup(caption: "大模型翻译（Responses 兼容）") {
                SettingsRow(title: "接口地址", subtitle: "必填，使用你自己的 Responses 兼容服务") {
                    SettingsTextField(
                        placeholder: "https://你的服务/v1",
                        text: Binding(
                            get: { settings.translationAPIBaseURL },
                            set: { settings.setTranslationAPIBaseURL($0) }
                        )
                    )
                }
                SettingsDivider()
                SettingsRow(title: "模型", subtitle: "必填，服务支持的模型名称") {
                    SettingsTextField(
                        placeholder: "模型名称",
                        text: Binding(
                            get: { settings.translationAPIModel },
                            set: { settings.setTranslationAPIModel($0) }
                        )
                    )
                }
                SettingsDivider()
                SettingsRow(title: "API 密钥", subtitle: apiKeyStatus ?? "必填，保存在本机钥匙串，仅用于向该服务认证") {
                    HStack(spacing: 8) {
                        SettingsTextField(placeholder: "sk-…", text: $apiKey, isSecure: true) {
                            saveAPIKey()
                        }
                        SettingsButton(title: "保存") { saveAPIKey() }
                    }
                }
            }
        }
        .onAppear {
            guard !apiKeyLoaded else { return }
            apiKeyLoaded = true
            apiKey = secrets.secret(for: SecretAccount.translationAPIKey) ?? ""
        }
    }

    private var indexTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "应用索引") {
                SettingsRow(
                    title: "已索引 \(appIndex.apps.count) 个应用",
                    subtitle: appIndex.lastError ?? (appIndex.isMonitoring
                        ? "安装、更新或移除应用后自动更新，也可手动重新扫描"
                        : "自动更新暂不可用，请手动重新扫描")
                ) {
                    HStack(spacing: 8) {
                        KeyCap(text: "⌘ R")
                        SettingsButton(title: "重新扫描", action: onRescan)
                    }
                }
            }
            SettingsGroup(caption: "文件搜索") {
                SettingsRow(title: "启用按需文件搜索", subtitle: "输入 file 加文件名开始搜索；关闭后不再查询 Spotlight") {
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
                SettingsDivider()
                SettingsRow(title: "应用更新", subtitle: "下载新版后，在应用内安装并重启") {
                    SettingsButton(title: "检查更新…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
                SettingsDivider()
                SettingsRow(title: "自动检查更新", subtitle: "每天检查一次，安装前由你确认") {
                    Toggle("自动检查更新", isOn: $updates.automaticallyChecksForUpdates).labelsHidden()
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
            (ProviderID.file.rawValue, "文件搜索", "输入 file 加文件名，按需查询 Spotlight"),
            (ProviderID.text.rawValue, "文本工具", "json、base64、url、时间戳、哈希、UUID"),
            (ProviderID.web.rawValue, "网页搜索", "关键词或默认引擎回退"),
            (ProviderID.translation.rawValue, "翻译", "tr 关键词调用配置的翻译 API"),
            (ProviderID.knowledge.rawValue, "知识库", "搜索、编辑和收集 DontsKb 内容"),
            (ProviderID.notes.rawValue, "本地便笺", "note · 所见即所得、Markdown 和图片"),
            (ProviderID.calculator.rawValue, "计算器", "算式与单位换算，回车复制结果"),
            (ProviderID.quickOpen.rawValue, "快速打开", "直接打开网址或已存在的绝对路径"),
            (ProviderID.gemini.rawValue, "Gemini 提问", "gm 加问题，新建对话并发送；自动输入需要辅助功能授权"),
            (ProviderID.ideaProjects.rawValue, "IDEA 项目", "idea 列出最近项目，idea 加名称筛选并打开")
        ]
    }

    private var geminiInstalled: Bool {
        appIndex.apps.contains { $0.bundleID == GeminiConversationService.applicationBundleIdentifier }
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
