import AppKit
import DontsToolCore
import SwiftUI
import UniformTypeIdentifiers

struct CloudSyncSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var websites: WebsiteShortcutStore
    @ObservedObject var searchEngines: SearchEngineStore
    @ObservedObject var notes: LocalNoteStore
    @ObservedObject var sync: CloudSyncCoordinator
    let secrets: SecretStoring
    let prepareBackup: @MainActor () async -> Void
    let didRestoreBackup: @MainActor () -> Void

    @State private var syncToken = ""
    @State private var tokenLoaded = false
    @State private var tokenStatus: String?
    @State private var actionStatus: String?
    @State private var actionIsError = false
    @State private var isTestingConnection = false
    @State private var isRunningBackupTask = false
    @State private var activeConflict: SyncConfigConflict?
    @State private var showingConfigHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !sync.pendingConflicts.isEmpty {
                SettingsGroup(caption: "待解决的同步冲突") {
                    ForEach(Array(sync.pendingConflicts.enumerated()), id: \.element.id) { index, conflict in
                        if index > 0 {
                            SettingsDivider()
                        }
                        SettingsRow(
                            title: conflict.displayTitle,
                            subtitle: "\(conflict.reasonSummary)（云端 rev \(conflict.remoteRevision)）"
                        ) {
                            SettingsButton(title: "对比并解决…") {
                                activeConflict = conflict
                            }
                        }
                    }
                }
            }

            SettingsGroup(caption: "Cloudflare 多端同步") {
                SettingsRow(
                    title: "启用多端自动同步",
                    subtitle: "通过自建 Cloudflare Worker + Durable Object + R2 实时增量同步便笺、网址、搜索与设置"
                ) {
                    HStack(spacing: 10) {
                        SettingsBadge(text: statusBadge.text, tone: statusBadge.tone)
                        Toggle("", isOn: Binding(
                            get: { settings.cloudSyncEnabled },
                            set: { settings.setCloudSyncEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 8) {
                    SettingsRow(title: "服务地址", subtitle: "填部署后的 Worker 域名，例如 https://sync.example.com") {
                        SettingsTextField(
                            placeholder: "https://sync.你的域名.com",
                            text: Binding(
                                get: { settings.cloudSyncServerURL },
                                set: { settings.setCloudSyncServerURL($0) }
                            )
                        ) {
                            sync.reloadConfiguration(triggerSync: settings.cloudSyncEnabled)
                        }
                    }
                    if let urlWarning {
                        Text(urlWarning)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "同步密钥", subtitle: tokenStatus ?? "保存在本机钥匙串，与 Worker Secret SYNC_TOKEN 一致") {
                    HStack(spacing: 8) {
                        SettingsTextField(placeholder: "Bearer Token", text: $syncToken, isSecure: true) {
                            saveToken()
                        }
                        SettingsButton(title: "保存") { saveToken() }
                    }
                }
                SettingsDivider()
                SettingsRow(title: syncSubtitle, subtitle: "设备标识：\(settings.cloudSyncDeviceID.prefix(8))…") {
                    HStack(spacing: 8) {
                        SettingsButton(title: isTestingConnection ? "测试中…" : "测试连接") {
                            testConnection()
                        }
                        .disabled(isTestingConnection)
                        SettingsButton(title: sync.status == .syncing ? "同步中…" : "立即同步") {
                            Task { await sync.syncNow() }
                        }
                        .disabled(!settings.cloudSyncEnabled || sync.status == .syncing)
                    }
                }
            }

            SettingsGroup(caption: "本地备份与恢复") {
                SettingsRow(
                    title: "导出完整备份包",
                    subtitle: "打包所有本地便笺（含图片与最近删除）、网址快捷入口、搜索引擎与设置，不含密钥"
                ) {
                    SettingsButton(title: isRunningBackupTask ? "处理中…" : "导出 .zip…") {
                        exportBackup()
                    }
                    .disabled(isRunningBackupTask)
                }
                SettingsDivider()
                SettingsRow(
                    title: "从备份包恢复",
                    subtitle: "恢复前会校验文件哈希，并自动在 Application Support/DontsTool/Backups 留存当前状态快照"
                ) {
                    SettingsButton(title: "选择备份恢复…") {
                        restoreBackup()
                    }
                    .disabled(isRunningBackupTask)
                }
                SettingsDivider()
                SettingsRow(
                    title: "配置覆盖历史快照",
                    subtitle: "同步覆写或解决冲突前会自动在本地留存最近 10 份 JSON 快照"
                ) {
                    SettingsButton(title: "查看历史…") {
                        showingConfigHistory = true
                    }
                    .disabled(isRunningBackupTask)
                }
            }

            if let actionStatus {
                Text(actionStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(actionIsError ? Color.red : Theme.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                Text("模型服务 API 密钥与同步密钥只保存在本机钥匙串，不上传云端也不写入本地备份包")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            guard !tokenLoaded else { return }
            tokenLoaded = true
            syncToken = secrets.secret(for: SecretAccount.cloudSyncToken) ?? ""
        }
        .sheet(item: $activeConflict) { conflict in
            SyncConflictResolutionSheet(conflict: conflict, sync: sync)
        }
        .sheet(isPresented: $showingConfigHistory) {
            SyncConfigHistorySheet(sync: sync) { message in
                actionIsError = false
                actionStatus = message
            }
        }
    }

    private var urlWarning: String? {
        let trimmed = settings.cloudSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try CloudSyncOrigin(trimmed)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var statusBadge: (text: String, tone: SettingsBadge.Tone) {
        switch sync.status {
        case .disabled:
            ("已关闭", .neutral)
        case .unconfigured:
            ("待配置", .neutral)
        case .syncing:
            ("同步中…", .neutral)
        case .needsResolution(let count, _):
            ("有 \(count) 项冲突", .warning)
        case .failed:
            ("同步异常", .neutral)
        case .idle:
            (sync.isRealtimeConnected ? "实时已连接" : "就绪", .success)
        }
    }

    private var syncSubtitle: String {
        switch sync.status {
        case .disabled:
            return "开启后将在编辑、启动和系统唤醒时自动双向同步"
        case .unconfigured:
            return "请填写有效的服务地址并保存同步密钥"
        case .syncing:
            return "正在与 Cloudflare 同步节点交换变更…"
        case .needsResolution(let count, let lastSyncedAt):
            let suffix = lastSyncedAt.map { " · 上次同步 \(Self.dateFormatter.string(from: $0))" } ?? ""
            return "有 \(count) 项配置冲突待手动确认（其余便笺与配置仍正常同步）\(suffix)"
        case .failed(let message):
            return "上次同步失败：\(message)"
        case .idle(let lastSyncedAt):
            guard let lastSyncedAt else { return "已连接，等待首次同步" }
            return "上次同步：\(Self.dateFormatter.string(from: lastSyncedAt))"
        }
    }

    private func saveToken() {
        let trimmed = syncToken.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.setSecret(trimmed.isEmpty ? nil : trimmed, for: SecretAccount.cloudSyncToken)
        syncToken = trimmed
        tokenStatus = trimmed.isEmpty ? "已清除密钥" : "密钥已保存到钥匙串"
        sync.reloadConfiguration(triggerSync: settings.cloudSyncEnabled)
    }

    private func testConnection() {
        isTestingConnection = true
        actionStatus = nil
        actionIsError = false
        Task {
            defer { isTestingConnection = false }
            do {
                let health = try await sync.testConnection()
                actionIsError = false
                actionStatus = "连接正常：服务端 revision \(health.revision)，已存储 \(health.itemCount) 项同步记录。"
            } catch {
                actionIsError = true
                actionStatus = error.localizedDescription
            }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "DontsTool-Backup-\(Self.fileTimestampFormatter.string(from: Date())).zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isRunningBackupTask = true
        actionStatus = nil
        actionIsError = false
        Task {
            defer { isRunningBackupTask = false }
            await prepareBackup()
            do {
                try BackupArchiveService.exportArchive(
                    to: destination,
                    settings: settings,
                    websites: websites,
                    searchEngines: searchEngines,
                    notes: notes
                )
                actionIsError = false
                actionStatus = "已导出备份包：\(destination.lastPathComponent)"
            } catch {
                actionIsError = true
                actionStatus = error.localizedDescription
            }
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let archiveURL = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "确认从备份包恢复数据？"
        alert.informativeText = "将用备份包替换本机便笺、网址快捷入口、搜索引擎与常规设置；恢复前会自动保留一份当前数据快照到 Application Support/DontsTool/Backups。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复备份")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isRunningBackupTask = true
        actionStatus = nil
        actionIsError = false
        Task {
            defer { isRunningBackupTask = false }
            await prepareBackup()
            do {
                try BackupArchiveService.restoreArchive(
                    from: archiveURL,
                    settings: settings,
                    websites: websites,
                    searchEngines: searchEngines,
                    notes: notes
                )
                didRestoreBackup()
                actionIsError = false
                actionStatus = "已从 \(archiveURL.lastPathComponent) 恢复数据（当前状态快照已自动保留）。"
            } catch {
                actionIsError = true
                actionStatus = error.localizedDescription
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct SyncConfigHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sync: CloudSyncCoordinator
    let onRestored: (String) -> Void

    @State private var entries: [SyncConfigHistoryEntry] = []
    @State private var selectedEntryID: String?
    @State private var isRestoring = false
    @State private var errorMessage: String?

    private var selectedEntry: SyncConfigHistoryEntry? {
        entries.first { $0.id == selectedEntryID } ?? entries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("配置覆盖历史快照")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("每类配置保留最近 10 份")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Text("暂无历史快照")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("当云端同步即将覆盖本机配置或手动解决冲突前，系统会自动留存覆盖前配置。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.glassCardBorder, lineWidth: 0.5))
            } else {
                HStack(spacing: 12) {
                    List(entries, selection: $selectedEntryID) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.displayTitle)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text(Self.dateFormatter.string(from: entry.savedAt))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                            Text(entry.reason)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 3)
                        .tag(entry.id)
                    }
                    .frame(width: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ToolTheme.border, lineWidth: 0.5))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(selectedEntry.map { "\($0.displayTitle) · \(Self.dateFormatter.string(from: $0.savedAt))" } ?? "快照预览")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ToolTheme.toolbar)
                        ToolTheme.border.frame(height: 0.5)
                        ToolTextEditor(
                            text: .constant(selectedEntry?.json ?? ""),
                            readOnly: true,
                            json: true,
                            label: "历史配置 JSON"
                        )
                    }
                    .background(ToolTheme.editor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ToolTheme.border, lineWidth: 0.5))
                }
                .frame(maxHeight: .infinity)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let entry = selectedEntry {
                    Button(isRestoring ? "恢复中…" : "恢复此快照") {
                        restore(entry)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRestoring)
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 520)
        .background(Theme.footerBase)
        .onAppear {
            entries = sync.configHistory()
            selectedEntryID = entries.first?.id
        }
    }

    private func restore(_ entry: SyncConfigHistoryEntry) {
        isRestoring = true
        errorMessage = nil
        Task {
            defer { isRestoring = false }
            do {
                try await sync.restoreConfigHistory(entry)
                onRestored("已恢复「\(entry.displayTitle)」于 \(Self.dateFormatter.string(from: entry.savedAt)) 的快照。")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}
