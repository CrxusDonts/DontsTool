import DontsToolCore
import Foundation
import Security
import SwiftUI

struct GeneralSettingsTabView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var login: LoginItemManager
    let onHotKeyRecordingChanged: (Bool) -> Void

    var body: some View {
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
                SettingsGuideRow(title: "选择结果", keys: ["↑", "↓"])
                SettingsDivider()
                SettingsGuideRow(title: "执行操作", keys: ["↵"])
                SettingsDivider()
                SettingsGuideRow(title: "执行次操作", keys: ["⌘", "↵"])
                SettingsDivider()
                SettingsGuideRow(title: "查看全部操作", keys: ["⌘", "K"])
                SettingsDivider()
                SettingsGuideRow(title: "关闭面板", keys: ["esc"])
            }
            SettingsPrivacyNote()
        }
    }
}

struct SearchSettingsTabView: View {
    @ObservedObject var searchEngines: SearchEngineStore
    @ObservedObject var websites: WebsiteShortcutStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
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
}

struct IndexSettingsTabView: View {
    @ObservedObject var appIndex: AppIndex
    @ObservedObject var settings: SettingsStore
    let onRescan: () -> Void

    var body: some View {
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
}

struct AboutSettingsTabView: View {
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "关于") {
                SettingsRow(title: "DontsTool", subtitle: "个人自用的原生 macOS 效率启动器") {
                    SettingsBadge(text: "V1")
                }
                SettingsDivider()
                SettingsRow(title: "版本", subtitle: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") {
                    SettingsBadge(text: signingBadgeText)
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
            SettingsPrivacyNote()
        }
    }

    private var signingBadgeText: String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return "ad-hoc 签名"
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return "ad-hoc 签名"
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value else {
            return "ad-hoc 签名"
        }
        return (flags & SecCodeSignatureFlags.adhoc.rawValue) != 0 ? "ad-hoc 签名" : "Developer ID 签名"
    }
}

private struct SettingsGuideRow: View {
    let title: String
    let keys: [String]

    var body: some View {
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
}

private struct SettingsPrivacyNote: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 11))
            Text("设置与使用记录仅保存在本机")
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
