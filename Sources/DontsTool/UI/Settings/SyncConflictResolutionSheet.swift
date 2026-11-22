import DontsToolCore
import SwiftUI

struct SyncConflictResolutionSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case fieldMerge = "按字段合并"
        case fullDiff = "完整差异（JSON Diff）"
        case editMerged = "编辑合并 JSON"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let conflict: SyncConfigConflict
    @ObservedObject var sync: CloudSyncCoordinator

    @State private var mode: Mode = .fieldMerge
    @State private var fieldDiffs: [SyncConfigFieldDiff] = []
    @State private var fieldChoices: [String: SyncFieldChoice] = [:]
    @State private var mergedJSONText = ""
    @State private var hasManualJSONEdits = false
    @State private var lastProgrammaticJSON = ""
    @State private var editorRevision = 0
    @State private var validationError: String?
    @State private var comparison: JSONComparison?
    @State private var diffError: String?
    @State private var selectedDifferenceID: Int?
    @State private var leftSelection: EditorSelection?
    @State private var rightSelection: EditorSelection?
    @State private var isResolving = false
    @State private var actionError: String?

    private var localPrettyJSON: String {
        SyncConfigMerger.prettyJSON(from: conflict.localJSON)
    }

    private var remotePrettyJSON: String {
        SyncConfigMerger.prettyJSON(from: conflict.remoteJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Theme.separator.frame(height: 0.5)
            Picker("冲突查看模式", selection: $mode) {
                ForEach(Mode.allCases) { entry in
                    Text(entry.rawValue).tag(entry)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .fieldMerge:
                    fieldMergeBody
                case .fullDiff:
                    fullDiffBody
                case .editMerged:
                    editMergedBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let actionError {
                Text(actionError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Theme.separator.frame(height: 0.5)
            footer
        }
        .padding(20)
        .frame(width: 820, height: 640)
        .background(Theme.footerBase)
        .interactiveDismissDisabled(isResolving)
        .onAppear(perform: initializeState)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("解决同步冲突 · \(conflict.displayTitle)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                SettingsBadge(text: "云端 rev \(conflict.remoteRevision)", tone: .warning)
            }
            Text(conflict.reasonSummary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 14) {
                Label(
                    "本机修改：\(conflict.localUpdatedAt.map { Self.dateFormatter.string(from: $0) } ?? "未记录（旧快照/首次同步）")",
                    systemImage: "laptopcomputer"
                )
                Label(
                    "云端修改：\(Self.dateFormatter.string(from: conflict.remoteUpdatedAt)) · 设备 \(remoteDeviceLabel)",
                    systemImage: "icloud"
                )
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
        }
    }

    private var remoteDeviceLabel: String {
        let trimmed = conflict.remoteDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未知" }
        return "\(trimmed.prefix(8))…"
    }

    private var fieldMergeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("共 \(fieldDiffs.count) 个顶层字段存在差异")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if hasManualJSONEdits {
                    Text("已手动编辑 JSON，勾选将同步覆盖")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                }
                SettingsButton(title: "全部选本机") {
                    setAllFieldChoices(.local)
                }
                SettingsButton(title: "全部选云端") {
                    setAllFieldChoices(.remote)
                }
            }

            if fieldDiffs.isEmpty {
                VStack(spacing: 8) {
                    Text("未检测到顶层键差异，可切换到「完整差异（JSON Diff）」检查格式或直接选择保留一方。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.glassCardBorder, lineWidth: 0.5))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(fieldDiffs) { diff in
                            fieldDiffRow(diff)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func fieldDiffRow(_ diff: SyncConfigFieldDiff) -> some View {
        let choice = fieldChoices[diff.key] ?? .local
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(diff.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(diff.key)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                Text(diff.kind.rawValue)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(kindColor(diff.kind))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(kindColor(diff.kind).opacity(0.12), in: Capsule())
                Spacer()
                Picker("选择版本", selection: Binding(
                    get: { fieldChoices[diff.key] ?? .local },
                    set: { newValue in
                        fieldChoices[diff.key] = newValue
                        rebuildMergedJSON(force: true)
                    }
                )) {
                    Text("用本机").tag(SyncFieldChoice.local)
                    Text("用云端").tag(SyncFieldChoice.remote)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            HStack(alignment: .top, spacing: 10) {
                sidePreviewCard(
                    title: "本机",
                    text: diff.localPreview,
                    selected: choice == .local
                )
                sidePreviewCard(
                    title: "云端",
                    text: diff.remotePreview,
                    selected: choice == .remote
                )
            }
        }
        .padding(12)
        .background(Theme.glassCardFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.glassCardBorder, lineWidth: 0.5)
        )
    }

    private func sidePreviewCard(title: String, text: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(selected ? Theme.accent : Theme.tertiary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.secondary)
            }
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            selected ? Theme.accentFill : Theme.controlFill.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Theme.accentBorder : Theme.controlBorder, lineWidth: 0.5)
        )
    }

    private var fullDiffBody: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                editorPane(
                    title: "本机 JSON（只读）",
                    text: .constant(localPrettyJSON),
                    selection: leftSelection
                )
                editorPane(
                    title: "云端 JSON（只读 · rev \(conflict.remoteRevision)）",
                    text: .constant(remotePrettyJSON),
                    selection: rightSelection
                )
            }
            .frame(minHeight: 230)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("JSON Diff 路径级差异（点击定位）")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    if let comparison {
                        Text("共 \(comparison.total) 项（新增 \(comparison.added) · 删除 \(comparison.removed) · 修改 \(comparison.modified)）")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(ToolTheme.toolbar)

                ToolTheme.border.frame(height: 0.5)

                if let diffError {
                    Text("JSON 比对失败：\(diffError)")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(12)
                } else if let comparison {
                    if comparison.differences.isEmpty {
                        Text("两侧 JSON 结构完全一致。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .padding(12)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(comparison.differences) { difference in
                                    Button {
                                        selectedDifferenceID = difference.id
                                        if let range = difference.leftRange {
                                            leftSelection = EditorSelection(range: range)
                                        }
                                        if let range = difference.rightRange {
                                            rightSelection = EditorSelection(range: range)
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(difference.kind.rawValue)
                                                .foregroundStyle(kindColor(difference.kind))
                                                .frame(width: 34, alignment: .leading)
                                            Text(difference.path)
                                                .foregroundStyle(Theme.ink)
                                                .frame(width: 200, alignment: .leading)
                                            Text(difference.left)
                                                .foregroundStyle(Theme.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: "arrow.right")
                                                .foregroundStyle(Theme.tertiary)
                                            Text(difference.right)
                                                .foregroundStyle(Theme.ink)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .background(selectedDifferenceID == difference.id ? ToolTheme.selection : Color.clear)

                                    ToolTheme.border.frame(height: 0.5)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 185)
            .background(ToolTheme.editor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ToolTheme.border, lineWidth: 0.5))
        }
    }

    private func editorPane(title: String, text: Binding<String>, selection: EditorSelection?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ToolTheme.toolbar)
            ToolTheme.border.frame(height: 0.5)
            ToolTextEditor(
                text: text,
                readOnly: true,
                json: true,
                selection: selection,
                active: mode == .fullDiff,
                label: title
            )
        }
        .background(ToolTheme.editor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ToolTheme.border, lineWidth: 0.5))
    }

    private var editMergedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("可直接修改合并结果；保存前会实时校验配置结构。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                SettingsButton(title: "按字段勾选重新生成") {
                    rebuildMergedJSON(force: true)
                }
                SettingsButton(title: "格式化") {
                    let formatted = SyncConfigMerger.prettyJSON(from: mergedJSONText)
                    if !hasManualJSONEdits {
                        lastProgrammaticJSON = formatted
                    }
                    mergedJSONText = formatted
                    editorRevision += 1
                    validateMergedJSON()
                }
            }

            ToolTextEditor(
                text: $mergedJSONText,
                json: true,
                active: mode == .editMerged,
                editRevision: editorRevision,
                label: "合并后的配置 JSON"
            )
            .background(ToolTheme.editor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ToolTheme.border, lineWidth: 0.5))
            .onChange(of: mergedJSONText) { _, newValue in
                hasManualJSONEdits = (newValue != lastProgrammaticJSON)
                validateMergedJSON()
            }

            if let validationError {
                Text("校验未通过：\(validationError)")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("JSON 校验通过，可应用合并结果")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.success)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isResolving)

            Spacer()

            Button("采用云端") {
                resolve(.useRemote)
            }
            .disabled(isResolving)

            Button("保留本机") {
                resolve(.keepLocal)
            }
            .disabled(isResolving)

            Button(isResolving ? "应用中…" : "应用合并结果") {
                resolve(.useMergedJSON(mergedJSONText))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isResolving || validationError != nil)
        }
    }

    private func initializeState() {
        let diffs = SyncConfigMerger.topLevelFieldDiffs(
            entityKey: conflict.entityKey,
            localJSON: localPrettyJSON,
            remoteJSON: remotePrettyJSON
        )
        fieldDiffs = diffs

        var initialChoices: [String: SyncFieldChoice] = [:]
        for diff in diffs {
            if conflict.reason == .remoteDowngradeGuard {
                initialChoices[diff.key] = .local
            } else {
                initialChoices[diff.key] = diff.kind == .added ? .remote : .local
            }
        }
        fieldChoices = initialChoices
        rebuildMergedJSON(force: true)

        do {
            comparison = try SyncConfigMerger.compare(localJSON: localPrettyJSON, remoteJSON: remotePrettyJSON)
            diffError = nil
        } catch {
            comparison = nil
            diffError = error.localizedDescription
        }
    }

    private func setAllFieldChoices(_ choice: SyncFieldChoice) {
        for diff in fieldDiffs {
            fieldChoices[diff.key] = choice
        }
        rebuildMergedJSON(force: true)
    }

    private func rebuildMergedJSON(force: Bool) {
        guard force || !hasManualJSONEdits else { return }
        do {
            let built = try SyncConfigMerger.buildMergedJSON(
                localJSON: localPrettyJSON,
                remoteJSON: remotePrettyJSON,
                choices: fieldChoices
            )
            lastProgrammaticJSON = built
            mergedJSONText = built
            hasManualJSONEdits = false
            editorRevision += 1
            validateMergedJSON()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func validateMergedJSON() {
        validationError = sync.validateConfigJSON(mergedJSONText, for: conflict.entityKey)
    }

    private func resolve(_ resolution: SyncConflictResolution) {
        isResolving = true
        actionError = nil
        Task {
            defer { isResolving = false }
            do {
                try await sync.resolveConflict(entityKey: conflict.entityKey, resolution: resolution)
                dismiss()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func kindColor(_ kind: JSONDifference.Kind) -> Color {
        switch kind {
        case .added: Theme.success
        case .removed: Theme.warning
        case .modified: Theme.accent
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}
