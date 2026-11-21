import AppKit
import DontsToolCore
import SwiftUI

struct ToolsSettingsTabView: View {
    @ObservedObject var settings: SettingsStore
    let onOpenPlugins: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            SettingsGroup(caption: "扩展插件") {
                SettingsRow(
                    title: "更多工具请前往「插件」页安装与管理",
                    subtitle: "AI 快问、文件搜索、IDEA 项目、Chrome、终端与访达、结束进程等扩展均托管于官方插件仓库"
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
        }
    }

    private var providerEntries: [(id: String, name: String, hint: String)] {
        [
            (ProviderID.app.rawValue, "应用启动", "搜索并打开本机应用"),
            (ProviderID.text.rawValue, "文本工具", "json、base64、url、时间戳、哈希、UUID"),
            (ProviderID.web.rawValue, "网页搜索", "关键词或默认引擎回退"),
            (ProviderID.translation.rawValue, "翻译", "tr 关键词调用配置的大模型服务"),
            (ProviderID.notes.rawValue, "本地便笺", "note · 所见即所得、Markdown 和图片"),
            (ProviderID.calculator.rawValue, "计算器", "算式与单位换算，回车复制结果"),
            (ProviderID.quickOpen.rawValue, "快速打开", "直接打开网址或已存在的绝对路径")
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
}
