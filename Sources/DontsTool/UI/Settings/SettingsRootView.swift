import DontsToolCore
import SwiftUI

@MainActor
final class SettingsNavigationState: ObservableObject {
    @Published var tab: SettingsRootView.Tab = .general
    @Published var guideSearchQuery = ""
}

/// 设置窗口内容：172pt 侧边栏 + 分组表单（design/05-settings.html）。
struct SettingsRootView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "通用"
        case search = "搜索"
        case websites = "网址快捷入口"
        case tools = "工具"
        case plugins = "插件"
        case aiModels = "模型服务"
        case translation = "翻译"
        case sync = "同步与备份"
        case guide = "使用指南"
        case about = "关于"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .search: "magnifyingglass"
            case .websites: "link"
            case .tools: "wrench.and.screwdriver"
            case .plugins: "puzzlepiece.extension"
            case .aiModels: "sparkles"
            case .translation: "character.bubble"
            case .sync: "icloud"
            case .guide: "book.closed"
            case .about: "info.circle"
            }
        }
    }

    @ObservedObject var updates: AppUpdateController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var websites: WebsiteShortcutStore
    @ObservedObject var searchEngines: SearchEngineStore
    @ObservedObject var notes: LocalNoteStore
    @ObservedObject var sync: CloudSyncCoordinator
    @ObservedObject var login: LoginItemManager
    let secrets: SecretStoring
    let aiService: RemoteAIChatService
    @ObservedObject var appIndex: AppIndex
    @ObservedObject var selectionTranslation: SelectionTranslationController
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject var pluginSettings: PluginSettingsStore
    @ObservedObject var pluginSources: PluginSourceStore
    @ObservedObject var pluginInstaller: PluginInstaller
    @ObservedObject var navigation: SettingsNavigationState
    let onRescan: () -> Void
    let onReloadPlugins: () -> Void
    let onHotKeyRecordingChanged: (Bool) -> Void
    let onTryGuideQuery: (String) -> Void
    let prepareBackup: @MainActor () async -> Void
    let didRestoreBackup: @MainActor () -> Void

    private var tab: Tab { navigation.tab }

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
                case .general:
                    GeneralSettingsTabView(
                        settings: settings,
                        login: login,
                        onHotKeyRecordingChanged: onHotKeyRecordingChanged
                    )
                case .search:
                    SearchSettingsTabView(
                        searchEngines: searchEngines,
                        websites: websites,
                        appIndex: appIndex,
                        onRescan: onRescan
                    )
                case .websites:
                    WebsiteShortcutsSettingsView(store: websites)
                case .tools:
                    ToolsSettingsTabView(settings: settings)
                case .plugins:
                    PluginsSettingsTabView(
                        pluginManager: pluginManager,
                        pluginSettings: pluginSettings,
                        pluginSources: pluginSources,
                        pluginInstaller: pluginInstaller,
                        onReloadPlugins: onReloadPlugins
                    )
                case .aiModels:
                    AIModelsSettingsTabView(
                        settings: settings,
                        secrets: secrets,
                        aiService: aiService
                    )
                case .translation:
                    TranslationSettingsTabView(
                        settings: settings,
                        selectionTranslation: selectionTranslation,
                        secrets: secrets,
                        onOpenAIModels: { navigation.tab = .aiModels }
                    )
                case .sync:
                    CloudSyncSettingsView(
                        settings: settings,
                        websites: websites,
                        searchEngines: searchEngines,
                        notes: notes,
                        sync: sync,
                        secrets: secrets,
                        prepareBackup: prepareBackup,
                        didRestoreBackup: didRestoreBackup
                    )
                case .guide:
                    GuideSettingsTabView(
                        settings: settings,
                        searchQuery: $navigation.guideSearchQuery,
                        onTryQuery: onTryGuideQuery
                    )
                case .about:
                    AboutSettingsTabView(updates: updates)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.footerBase.opacity(0.4))
    }
}
