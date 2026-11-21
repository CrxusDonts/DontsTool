import AppKit
import DontsToolCore
import SwiftUI

private struct PendingBatchInstall: Identifiable {
    let id = UUID()
    let source: PluginSource
    let items: [StagedPluginInstall]
}

struct PluginsSettingsTabView: View {
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject var pluginSettings: PluginSettingsStore
    @ObservedObject var pluginSources: PluginSourceStore
    @ObservedObject var pluginInstaller: PluginInstaller
    let onReloadPlugins: () -> Void

    @State private var newSourceInput = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isCheckingUpdates = false
    @State private var isPreparingBatch = false
    @State private var hasAutoLoadedCatalogs = false
    @State private var pendingInstall: StagedPluginInstall?
    @State private var pendingBatchInstall: PendingBatchInstall?
    @State private var pendingUninstall: PluginLoadRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let statusMessage {
                statusBanner(message: statusMessage, isError: statusIsError)
            }

            installedPluginsSection
            addSourceSection

            ForEach(pluginSources.sources) { source in
                sourceCatalogSection(for: source)
            }
        }
        .onAppear {
            guard !hasAutoLoadedCatalogs else { return }
            hasAutoLoadedCatalogs = true
            if pluginInstaller.catalogsBySourceID.isEmpty {
                Task {
                    await pluginInstaller.refreshAllCatalogs(for: pluginSources.sources)
                }
            }
        }
        .sheet(item: $pendingInstall) { staged in
            PluginInstallConfirmationSheet(
                staged: staged,
                onConfirm: { allowSourceOverride in
                    try await pluginInstaller.commitInstall(staged, allowSourceOverride: allowSourceOverride)
                    let actionWord = staged.isUpdate ? "更新" : "安装"
                    showStatus("已\(actionWord)插件「\(staged.manifest.name)」v\(staged.manifest.version)", isError: false)
                },
                onCleanup: {
                    pluginInstaller.cleanupStagedInstall(staged)
                }
            )
        }
        .sheet(item: $pendingBatchInstall) { batch in
            BatchPluginInstallConfirmationSheet(
                sourceName: batch.source.name,
                items: batch.items,
                onConfirm: { allowSourceOverride in
                    var installedCount = 0
                    var failedNames: [String] = []
                    for item in batch.items {
                        do {
                            try await pluginInstaller.commitInstall(item, allowSourceOverride: allowSourceOverride)
                            installedCount += 1
                        } catch {
                            pluginInstaller.cleanupStagedInstall(item)
                            failedNames.append("\(item.manifest.name)（\(error.localizedDescription)）")
                        }
                    }
                    if failedNames.isEmpty {
                        showStatus("已成功安装 \(installedCount) 个推荐插件", isError: false)
                    } else {
                        showStatus(
                            "已安装 \(installedCount) 个插件，\(failedNames.count) 个失败：\(failedNames.joined(separator: "；"))",
                            isError: true
                        )
                    }
                },
                onCleanup: {
                    for item in batch.items {
                        pluginInstaller.cleanupStagedInstall(item)
                    }
                }
            )
        }
        .alert(item: $pendingUninstall) { record in
            Alert(
                title: Text("卸载「\(record.name)」？"),
                message: Text("将从用户插件目录移除 \(record.id) 并立即停用其进程，已保存的插件偏好设置不会丢失。"),
                primaryButton: .destructive(Text("卸载")) {
                    uninstall(record)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - 区块 1：已安装插件

    private var installedPluginsSection: some View {
        SettingsGroup(caption: "已安装插件") {
            SettingsRow(title: "本地插件管理", subtitle: installedSummary) {
                HStack(spacing: 8) {
                    SettingsButton(title: "打开插件目录") {
                        openPluginsDirectory()
                    }
                    SettingsButton(title: "重新加载") {
                        onReloadPlugins()
                    }
                    SettingsButton(title: isCheckingUpdates ? "检查中…" : "检查更新") {
                        checkForUpdates()
                    }
                    .disabled(isCheckingUpdates || !pluginInstaller.loadingSourceIDs.isEmpty)
                    .opacity((isCheckingUpdates || !pluginInstaller.loadingSourceIDs.isEmpty) ? 0.55 : 1)
                }
            }

            if pluginManager.records.isEmpty {
                SettingsDivider()
                Text("尚未安装任何插件。可在下方官方插件源一键安装推荐插件，或将本地插件放入用户插件目录后点击「重新加载」。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(pluginManager.records) { record in
                    SettingsDivider()
                    installedPluginRow(for: record)
                }
            }
        }
    }

    private var installedSummary: String {
        let loaded = pluginManager.records.filter { $0.status == .loaded }.count
        let failed = pluginManager.records.count - loaded
        let updates = pluginManager.records.filter { pluginInstaller.availableUpdate(for: $0.id) != nil }.count
        var parts = ["已加载 \(loaded) 个插件"]
        if failed > 0 {
            parts.append("\(failed) 个加载异常")
        }
        if updates > 0 {
            parts.append("\(updates) 个可更新")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func installedPluginRow(for record: PluginLoadRecord) -> some View {
        let metadata = pluginInstaller.installedMetadata(for: record.id)
        let sourceLabel: String = {
            if let repo = metadata?.sourceRepo, !repo.isEmpty {
                return repo
            }
            return record.origin == .bundled ? "官方预装" : "本地插件"
        }()
        let versionLabel = record.version.map { "v\($0)" } ?? "未知版本"
        let updateInfo = pluginInstaller.availableUpdate(for: record.id)
        let isBusy = pluginInstaller.activePluginOperations.contains(record.id) || isPreparingBatch

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(Theme.settingTitleFont)
                        .foregroundStyle(Theme.ink)
                    Text(versionLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                    sourceTagPill(sourceLabel, isLocal: metadata == nil && record.origin == .user)
                    if let updateInfo {
                        accentPill("可更新至 v\(updateInfo.entry.version)")
                    }
                }

                switch record.status {
                case .loaded:
                    HStack(spacing: 6) {
                        if !record.keywords.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(Array(record.keywords.prefix(4)), id: \.self) { keyword in
                                    ShortcutTag(keyword: keyword)
                                }
                            }
                        }
                        if let description = record.description, !description.isEmpty {
                            Text(description)
                                .font(Theme.settingSubtitleFont)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(2)
                        }
                    }
                case .failed(let message):
                    Text("加载失败：\(message)")
                        .font(Theme.settingSubtitleFont)
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let updateInfo {
                    SettingsButton(title: isBusy ? "处理中…" : "更新") {
                        beginInspect(
                            entry: updateInfo.entry,
                            source: updateInfo.source,
                            catalogURL: updateInfo.catalogURL
                        )
                    }
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.55 : 1)
                }

                switch record.status {
                case .loaded:
                    Toggle("", isOn: Binding(
                        get: { pluginManager.isRecordEnabled(record) },
                        set: { pluginManager.setRecordEnabled(record, to: $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(isBusy)
                case .failed:
                    SettingsBadge(text: "加载失败")
                }

                if record.origin == .user {
                    SettingsButton(title: "卸载") {
                        pendingUninstall = record
                    }
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.55 : 1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 区块 2：插件源与安装

    private var addSourceSection: some View {
        SettingsGroup(caption: "插件源与安装") {
            SettingsRow(
                title: "添加插件源",
                subtitle: "支持 GitHub 单插件仓、多插件合集仓（owner/repo）或直接输入 catalog.json 链接"
            ) {
                HStack(spacing: 8) {
                    SettingsTextField(
                        placeholder: "owner/repo 或 https://…/catalog.json",
                        text: $newSourceInput,
                        onSubmit: addSource
                    )
                    SettingsButton(title: "添加源") {
                        addSource()
                    }
                    .disabled(newSourceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(newSourceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                }
            }
        }
    }

    private func sourceCatalogSection(for source: PluginSource) -> some View {
        let fetched = pluginInstaller.catalogsBySourceID[source.id]
        let isLoading = pluginInstaller.loadingSourceIDs.contains(source.id)
        let loadError = pluginInstaller.sourceErrors[source.id]
        let pendingRecommended = recommendedEntriesToInstall(for: source, fetched: fetched)

        return SettingsGroup(caption: source.isBuiltIn ? "官方插件源" : "自定义插件源") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(source.name)
                            .font(Theme.settingTitleFont)
                            .foregroundStyle(Theme.ink)
                        if source.isBuiltIn {
                            SettingsBadge(text: "官方", tone: .success)
                        } else if fetched?.isSinglePluginFallback == true {
                            SettingsBadge(text: "单插件仓")
                        }
                        if let count = fetched?.catalog.plugins.count {
                            Text("共 \(count) 个插件")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    Text(source.location)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let loadError {
                        Text("拉取失败：\(loadError)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if source.isBuiltIn, let fetched, !fetched.catalog.plugins.isEmpty {
                        let hasRecommended = !pendingRecommended.isEmpty
                        SettingsButton(
                            title: isPreparingBatch
                                ? "校验中…"
                                : (hasRecommended ? "安装全部推荐插件" : "已全部安装")
                        ) {
                            beginBatchInspect(entries: pendingRecommended, source: source, catalogURL: fetched.resolvedURL)
                        }
                        .disabled(!hasRecommended || isPreparingBatch || isLoading)
                        .opacity((!hasRecommended || isPreparingBatch || isLoading) ? 0.55 : 1)
                    }

                    SettingsButton(title: isLoading ? "刷新中…" : "刷新") {
                        refreshSource(source)
                    }
                    .disabled(isLoading)
                    .opacity(isLoading ? 0.55 : 1)

                    if !source.isBuiltIn {
                        SettingsButton(title: "移除") {
                            if pluginSources.removeSource(id: source.id) {
                                showStatus("已移除插件源「\(source.name)」", isError: false)
                            }
                        }
                        .disabled(isLoading)
                        .opacity(isLoading ? 0.55 : 1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if let fetched {
                ForEach(fetched.catalog.plugins) { entry in
                    SettingsDivider()
                    catalogEntryRow(entry: entry, source: source, catalogURL: fetched.resolvedURL)
                }
            } else if isLoading {
                SettingsDivider()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在拉取插件目录…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if loadError == nil {
                SettingsDivider()
                Text("点击「刷新」从 \(source.location) 拉取可用插件列表。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func catalogEntryRow(
        entry: PluginCatalogEntry,
        source: PluginSource,
        catalogURL: URL
    ) -> some View {
        let status = pluginInstaller.catalogEntryStatus(for: entry)
        let isBusy = pluginInstaller.activePluginOperations.contains(entry.id) || isPreparingBatch

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(Theme.settingTitleFont)
                        .foregroundStyle(Theme.ink)
                    Text("v\(entry.version)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                    if entry.official == true {
                        accentPill("官方推荐")
                    }
                }
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Theme.settingSubtitleFont)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text(entry.id)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                    if let minHost = entry.minHostVersion, !minHost.isEmpty {
                        Text("需宿主 ≥ v\(minHost)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                switch status {
                case .notInstalled:
                    SettingsBadge(text: "未安装")
                    SettingsButton(title: isBusy ? "下载校验中…" : "安装") {
                        beginInspect(entry: entry, source: source, catalogURL: catalogURL)
                    }
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.55 : 1)
                case let .updateAvailable(installedVersion, latestVersion):
                    SettingsBadge(text: "可更新 v\(installedVersion) → v\(latestVersion)")
                    SettingsButton(title: isBusy ? "下载校验中…" : "更新") {
                        beginInspect(entry: entry, source: source, catalogURL: catalogURL)
                    }
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.55 : 1)
                case .upToDate:
                    SettingsBadge(text: "已安装", tone: .success)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Helpers & Actions

    private func recommendedEntriesToInstall(
        for source: PluginSource,
        fetched: FetchedPluginCatalog?
    ) -> [PluginCatalogEntry] {
        guard source.isBuiltIn, let fetched else { return [] }
        let officialMarked = fetched.catalog.plugins.filter { $0.official == true }
        let candidates = officialMarked.isEmpty ? fetched.catalog.plugins : officialMarked
        return candidates.filter { entry in
            switch pluginInstaller.catalogEntryStatus(for: entry) {
            case .notInstalled, .updateAvailable:
                return true
            case .upToDate:
                return false
            }
        }
    }

    private func addSource() {
        let raw = newSourceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        do {
            let added = try pluginSources.addSource(location: raw)
            newSourceInput = ""
            showStatus("已添加插件源「\(added.name)」，正在拉取目录…", isError: false)
            refreshSource(added)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func refreshSource(_ source: PluginSource) {
        Task {
            do {
                let fetched = try await pluginInstaller.fetchCatalog(for: source)
                showStatus("已刷新「\(source.name)」，共 \(fetched.catalog.plugins.count) 个插件", isError: false)
            } catch {
                showStatus("刷新「\(source.name)」失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private func checkForUpdates() {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        Task {
            defer { isCheckingUpdates = false }
            await pluginInstaller.refreshAllCatalogs(for: pluginSources.sources)
            let updateCount = pluginManager.records.filter {
                pluginInstaller.availableUpdate(for: $0.id) != nil
            }.count
            if updateCount > 0 {
                showStatus("发现 \(updateCount) 个已安装插件有新版本可用", isError: false)
            } else {
                showStatus("已检查全部插件源，当前已安装插件均为最新版本", isError: false)
            }
        }
    }

    private func beginInspect(entry: PluginCatalogEntry, source: PluginSource, catalogURL: URL?) {
        Task {
            do {
                let staged = try await pluginInstaller.inspectPackage(
                    entry: entry,
                    from: source,
                    catalogURL: catalogURL
                )
                pendingInstall = staged
            } catch {
                showStatus("下载或校验「\(entry.name)」失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private func beginBatchInspect(entries: [PluginCatalogEntry], source: PluginSource, catalogURL: URL?) {
        guard !entries.isEmpty, !isPreparingBatch else { return }
        isPreparingBatch = true
        Task {
            defer { isPreparingBatch = false }
            var stagedList: [StagedPluginInstall] = []
            var failures: [String] = []
            for entry in entries {
                do {
                    let staged = try await pluginInstaller.inspectPackage(
                        entry: entry,
                        from: source,
                        catalogURL: catalogURL
                    )
                    stagedList.append(staged)
                } catch {
                    failures.append("\(entry.name)：\(error.localizedDescription)")
                }
            }
            if !stagedList.isEmpty {
                pendingBatchInstall = PendingBatchInstall(source: source, items: stagedList)
                if !failures.isEmpty {
                    showStatus("部分推荐插件校验失败：\(failures.joined(separator: "；"))", isError: true)
                }
            } else if !failures.isEmpty {
                showStatus("无法准备推荐插件：\(failures.joined(separator: "；"))", isError: true)
            }
        }
    }

    private func uninstall(_ record: PluginLoadRecord) {
        Task {
            do {
                try await pluginInstaller.uninstall(pluginID: record.id)
                showStatus("已卸载插件「\(record.name)」", isError: false)
            } catch {
                showStatus("卸载「\(record.name)」失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private func openPluginsDirectory() {
        if let dir = try? pluginManager.ensureUserPluginsDirectoryExists() {
            NSWorkspace.shared.open(dir)
        }
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func statusBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isError ? Color.red : Theme.success)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(isError ? Color.red : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                statusMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (isError ? Color.red : Theme.success).opacity(0.08),
            in: RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius)
                .strokeBorder((isError ? Color.red : Theme.success).opacity(0.24), lineWidth: 0.6)
        )
    }

    private func sourceTagPill(_ text: String, isLocal: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: isLocal ? .default : .monospaced))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.controlFill, in: Capsule())
    }

    private func accentPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accentFill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Theme.accentBorder, lineWidth: 0.5)
            )
    }
}

// MARK: - 安装前权限确认 Sheet（单插件）

private struct PluginInstallConfirmationSheet: View {
    let staged: StagedPluginInstall
    let onConfirm: @MainActor (Bool) async throws -> Void
    let onCleanup: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var allowSourceOverride = false
    @State private var isCommitting = false
    @State private var didCommit = false
    @State private var errorMessage: String?

    private var sortedPermissions: [PluginPermission] {
        staged.manifest.permissions.sorted { $0.rawValue < $1.rawValue }
    }

    private var canConfirm: Bool {
        !isCommitting && (!staged.hasSourceConflict || allowSourceOverride)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.accentBorder, lineWidth: 0.6)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(staged.isUpdate ? "确认更新插件" : "确认安装插件")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("\(staged.manifest.name)（\(staged.manifest.id)）")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup(caption: "插件信息") {
                        metaRow(
                            title: "版本",
                            value: staged.isUpdate,
                            text: {
                                if let existing = staged.existingVersion, staged.isUpdate {
                                    return "v\(existing) → v\(staged.manifest.version)"
                                }
                                return "v\(staged.manifest.version)"
                            }()
                        )
                        SettingsDivider()
                        metaRow(title: "来源仓库", value: false, text: staged.sourceRepo)
                        if !staged.manifest.keywords.isEmpty {
                            SettingsDivider()
                            metaRow(
                                title: "触发关键词",
                                value: false,
                                text: staged.manifest.keywords.joined(separator: " / ")
                            )
                        }
                        SettingsDivider()
                        SettingsRow(title: "SHA-256 校验") {
                            HStack(spacing: 6) {
                                Image(systemName: staged.sha256Verified ? "checkmark.shield.fill" : "exclamationmark.shield")
                                    .font(.system(size: 12))
                                    .foregroundStyle(staged.sha256Verified ? Theme.success : Theme.warning)
                                Text(staged.sha256Verified ? "校验通过" : "目录未提供哈希")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(staged.sha256Verified ? Theme.success : Theme.warning)
                                Text(String(staged.sha256.prefix(12)) + "…")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.tertiary)
                                    .help(staged.sha256)
                            }
                        }
                    }

                    SettingsGroup(caption: "申请的宿主权限（\(sortedPermissions.count) 项）") {
                        if sortedPermissions.isEmpty {
                            Text("此插件未申请敏感系统权限。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(Array(sortedPermissions.enumerated()), id: \.element) { index, permission in
                                if index > 0 { SettingsDivider() }
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.accent)
                                    Text(permission.displayName)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text(permission.rawValue)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            }
                        }
                    }

                    if staged.hasSourceConflict {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.warning)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("跨源同名插件冲突警告")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Theme.warning)
                                    Text("已安装的「\(staged.manifest.id)」来自源「\(staged.existingSourceRepo ?? "未知来源")」，即将安装的包来自「\(staged.sourceRepo)」。请确认来源可信后再覆盖。")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Toggle("我了解风险，确认覆盖来自其他源的同名插件", isOn: $allowSourceOverride)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius)
                                .strokeBorder(Theme.warning.opacity(0.4), lineWidth: 0.8)
                        )
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxHeight: 330)

            HStack {
                Spacer()
                SettingsButton(title: "取消") {
                    dismiss()
                }
                .disabled(isCommitting)

                Button {
                    commit()
                } label: {
                    Text(isCommitting ? "安装中…" : (staged.isUpdate ? "确认更新" : "确认安装"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            canConfirm ? Theme.accent : Theme.accent.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canConfirm)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onDisappear {
            if !didCommit {
                onCleanup()
            }
        }
    }

    private func metaRow(title: String, value: Bool, text: String) -> some View {
        SettingsRow(title: title) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(value ? Theme.accent : Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func commit() {
        guard canConfirm else { return }
        isCommitting = true
        errorMessage = nil
        Task {
            defer { isCommitting = false }
            do {
                try await onConfirm(allowSourceOverride)
                didCommit = true
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 批量推荐插件权限确认 Sheet

private struct BatchPluginInstallConfirmationSheet: View {
    let sourceName: String
    let items: [StagedPluginInstall]
    let onConfirm: @MainActor (Bool) async -> Void
    let onCleanup: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var allowSourceOverride = false
    @State private var isCommitting = false
    @State private var didCommit = false

    private var hasAnyConflict: Bool {
        items.contains(where: \.hasSourceConflict)
    }

    private var combinedPermissions: [PluginPermission] {
        var all = Set<PluginPermission>()
        for item in items {
            all.formUnion(item.manifest.permissions)
        }
        return all.sorted { $0.rawValue < $1.rawValue }
    }

    private var canConfirm: Bool {
        !isCommitting && (!hasAnyConflict || allowSourceOverride)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.accentBorder, lineWidth: 0.6)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("安装全部推荐插件（\(items.count) 个）")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("来源：\(sourceName)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup(caption: "待安装列表") {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { SettingsDivider() }
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.manifest.name)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(Theme.ink)
                                        Text("v\(item.manifest.version)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(Theme.tertiary)
                                    }
                                    Text(item.manifest.keywords.isEmpty ? item.manifest.id : item.manifest.keywords.joined(separator: " / "))
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Image(systemName: item.sha256Verified ? "checkmark.shield.fill" : "exclamationmark.shield")
                                    .font(.system(size: 12))
                                    .foregroundStyle(item.sha256Verified ? Theme.success : Theme.warning)
                                    .help(item.sha256Verified ? "已通过 SHA-256 校验" : "目录未提供 SHA-256")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }

                    SettingsGroup(caption: "合并申请的宿主权限（\(combinedPermissions.count) 项）") {
                        if combinedPermissions.isEmpty {
                            Text("这些插件未申请敏感系统权限。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(Array(combinedPermissions.enumerated()), id: \.element) { index, permission in
                                if index > 0 { SettingsDivider() }
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.accent)
                                    Text(permission.displayName)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text(permission.rawValue)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                            }
                        }
                    }

                    if hasAnyConflict {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("检测到部分已安装插件来自其他源，覆盖安装前请显式确认。")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.warning)
                            Toggle("我了解风险，确认覆盖来自其他源的同名插件", isOn: $allowSourceOverride)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.settingsGroupCornerRadius)
                                .strokeBorder(Theme.warning.opacity(0.4), lineWidth: 0.8)
                        )
                    }
                }
            }
            .frame(maxHeight: 330)

            HStack {
                Spacer()
                SettingsButton(title: "取消") {
                    dismiss()
                }
                .disabled(isCommitting)

                Button {
                    guard canConfirm else { return }
                    isCommitting = true
                    Task {
                        defer { isCommitting = false }
                        await onConfirm(allowSourceOverride)
                        didCommit = true
                        dismiss()
                    }
                } label: {
                    Text(isCommitting ? "安装中…" : "确认安装（\(items.count)）")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            canConfirm ? Theme.accent : Theme.accent.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canConfirm)
            }
        }
        .padding(18)
        .frame(width: 500)
        .onDisappear {
            if !didCommit {
                onCleanup()
            }
        }
    }
}
