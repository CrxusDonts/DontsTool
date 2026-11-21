import AppKit
import DontsToolCore
import SwiftUI

struct ToolsSettingsTabView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var appIndex: AppIndex
    @ObservedObject var selectionTranslation: SelectionTranslationController
    let onOpenPlugins: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "内置工具") {
                ForEach(Array(providerEntries.enumerated()), id: \.offset) { offset, entry in
                    if offset > 0 { SettingsDivider() }
                    SettingsRow(
                        title: entry.name,
                        subtitle: entry.id == ProviderID.gemini.rawValue && !geminiInstalled
                            ? (appIndex.isScanning ? "正在检测 Gemini Mac 版…" : "未安装 Gemini Mac 版，安装后可启用")
                            : entry.hint
                    ) {
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

            SettingsGroup(caption: "扩展插件") {
                SettingsRow(
                    title: "更多工具请前往「插件」页安装与管理",
                    subtitle: "文件搜索、IDEA 项目、Chrome、终端与访达、结束进程等扩展已迁至官方插件仓库"
                ) {
                    SettingsButton(title: "前往插件") {
                        onOpenPlugins()
                    }
                }
            }

            SettingsGroup(caption: "终端与访达") {
                SettingsRow(
                    title: "默认终端",
                    subtitle: "用于快速打开以及外部插件（文件搜索、IDEA 项目、终端与访达等）的「在终端中打开」"
                ) {
                    Picker("", selection: Binding(
                        get: { settings.preferredTerminalBundleID },
                        set: { settings.setPreferredTerminalBundleID($0) }
                    )) {
                        Text("自动（优先当前运行终端）").tag("")
                        ForEach(installedTerminals) { terminal in
                            Text(terminal.displayName).tag(terminal.bundleID)
                        }
                        if let unavailablePreferredTerminal {
                            Text("\(unavailablePreferredTerminal.displayName)（未安装）").tag(unavailablePreferredTerminal.bundleID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 210)
                }
            }

            SettingsGroup(caption: "Gemini 自动提问") {
                SettingsRow(
                    title: "Gemini Mac 版",
                    subtitle: geminiInstalled
                        ? "已在本机应用索引中找到 Gemini"
                        : (appIndex.isScanning ? "正在检测本机应用…" : "安装 Gemini Mac 版后，此功能才可使用")
                ) {
                    SettingsBadge(
                        text: geminiInstalled ? "已安装" : (appIndex.isScanning ? "检测中" : "未安装"),
                        tone: geminiInstalled ? .success : .neutral
                    )
                }
                if geminiInstalled {
                    SettingsDivider()
                    SettingsRow(
                        title: selectionTranslation.accessibilityGranted ? "辅助功能已授权" : "自动输入需要辅助功能授权",
                        subtitle: "只在执行 gm 问题时操作 Gemini；仅打开应用无需此权限"
                    ) {
                        if !selectionTranslation.accessibilityGranted {
                            SettingsButton(title: "授权辅助功能") { selectionTranslation.requestAccessibility() }
                        }
                    }
                }
                Text("如果 Gemini 已有未发送草稿，会停止自动提问并保留草稿。问题仅在回车执行后交给 Gemini，不进入剪贴板或日志。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(12)
            }
        }
    }

    private var providerEntries: [(id: String, name: String, hint: String)] {
        [
            (ProviderID.app.rawValue, "应用启动", "搜索并打开本机应用"),
            (ProviderID.text.rawValue, "文本工具", "json、base64、url、时间戳、哈希、UUID"),
            (ProviderID.web.rawValue, "网页搜索", "关键词或默认引擎回退"),
            (ProviderID.translation.rawValue, "翻译", "tr 关键词调用配置的翻译 API"),
            (ProviderID.notes.rawValue, "本地便笺", "note · 所见即所得、Markdown 和图片"),
            (ProviderID.calculator.rawValue, "计算器", "算式与单位换算，回车复制结果"),
            (ProviderID.quickOpen.rawValue, "快速打开", "直接打开网址或已存在的绝对路径"),
            (ProviderID.gemini.rawValue, "Gemini 提问", "gm 加问题，新建对话并发送；自动输入需要辅助功能授权")
        ]
    }

    private var installedTerminals: [TerminalAppDescriptor] {
        SystemTerminalFinderService().installedTerminals()
    }

    private var unavailablePreferredTerminal: TerminalAppDescriptor? {
        let configured = settings.preferredTerminalBundleID
        guard !configured.isEmpty,
              !installedTerminals.contains(where: { $0.matches(bundleID: configured) }) else {
            return nil
        }
        return TerminalAppCatalog.descriptor(forBundleID: configured)
            ?? TerminalAppDescriptor(bundleID: configured, displayName: configured)
    }

    private var geminiInstalled: Bool {
        appIndex.apps.contains { $0.bundleID == GeminiConversationService.applicationBundleIdentifier }
    }
}
