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

            SettingsGroup(caption: "系统偏好") {
                SettingsRow(
                    title: "首选终端",
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

            SettingsPrivacyNote()
        }
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

struct SearchSettingsTabView: View {
    @ObservedObject var searchEngines: SearchEngineStore
    @ObservedObject var websites: WebsiteShortcutStore
    @ObservedObject var appIndex: AppIndex
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SearchEnginesSettingsView(store: searchEngines, websites: websites)
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
        }
    }
}

struct AboutSettingsTabView: View {
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "关于") {
                SettingsRow(title: "DontsTool", subtitle: "个人自用的原生 macOS 效率启动器") {
                    EmptyView()
                }
                SettingsDivider()
                SettingsRow(title: "版本", subtitle: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") {
                    SettingsBadge(text: signingBadgeText)
                }
                SettingsDivider()
                SettingsRow(
                    title: "应用更新",
                    subtitle: updates.availableUpdateVersion.map { "发现新版本 \($0)，点击查看更新说明并安装" }
                        ?? "下载新版后，在应用内安装并重启"
                ) {
                    SettingsButton(title: updates.availableUpdateVersion.map { "更新到 \($0)…" } ?? "检查更新…") {
                        updates.checkForUpdates()
                    }
                    .disabled(!updates.canCheckForUpdates)
                }
                SettingsDivider()
                SettingsRow(title: "自动检查更新", subtitle: "每日首次打开启动器时静默检查一次，安装前由你确认") {
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
