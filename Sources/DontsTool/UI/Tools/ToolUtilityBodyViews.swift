import AppKit
import DontsToolCore
import SwiftUI

extension ToolWorkspaceView {
    var textEditorBody: some View {
        ToolEditorPane(
            title: session.kind == .json ? "JSON" : "内容",
            text: $session.input,
            json: session.kind == .json,
            wrap: wrap,
            folding: session.kind == .json,
            selection: inputSelection,
            active: session.kind != .json || !session.comparing,
            editRevision: draftEditor.revision,
            undoManager: draftEditor.undoManager
        ) {
            Button("粘贴") {
                guard let value = NSPasteboard.general.string(forType: .string) else { return }
                if session.kind == .json {
                    draftEditor.replaceInput(JSONPaste.formatted(value) ?? value, actionName: "粘贴")
                } else {
                    session.input = value
                }
            }
            Button("清空") { draftEditor.replaceInput("") }
            Button("复制") { copy(session.input) }
            if session.kind == .json {
                Menu("对比") {
                    Button("送到左侧") { draftEditor.replaceComparisonSide(session.input, right: false) }
                    Button("送到右侧") { draftEditor.replaceComparisonSide(session.input, right: true) }
                }
            }
        }
    }

    var compactUtilityBody: some View {
        VStack(spacing: 4) {
            ToolEditorPane(
                title: session.kind == .timestamp ? "时间戳或日期" : "文本",
                text: $session.input,
                wrap: wrap,
                selection: inputSelection,
                editRevision: draftEditor.revision,
                undoManager: draftEditor.undoManager
            ) {
                Button("粘贴") { paste(into: &session.input) }
                Button("清空") { draftEditor.replaceInput("") }
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(session.kind == .timestamp ? "转换结果" : "哈希结果").fontWeight(.semibold)
                    if session.hasStaleResult { Text("旧结果已过期，请重新处理").foregroundStyle(Theme.warning) }
                    Spacer(minLength: 4)
                    Button("复制结果") { copy(session.output) }.disabled(!session.canCopy).controlSize(.small)
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(ToolTheme.toolbar)

                ToolTheme.border.frame(height: 0.5)

                if let timestamp = session.timestamp, session.kind == .timestamp {
                    resultRow("秒", value: timestamp.seconds)
                    ToolTheme.border.frame(height: 0.5)
                    resultRow("毫秒", value: timestamp.milliseconds)
                    ToolTheme.border.frame(height: 0.5)
                    resultRow("日期", value: timestamp.date)
                } else {
                    Text(session.hasResult ? session.output : "执行后在这里查看结果")
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(session.hasResult ? ToolTheme.ink : ToolTheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(ToolTheme.editor)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ToolTheme.border, lineWidth: 0.5))
            .padding(4)
        }
    }

    private func resultRow(_ title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(ToolTheme.secondary).frame(width: 44, alignment: .leading)
            Text(value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 8)
            Button("复制") { copy(value) }.disabled(!session.canCopy).controlSize(.small).accessibilityLabel("复制" + title)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    var translationBody: some View {
        HSplitView {
            ToolEditorPane(
                title: "原文",
                text: $session.input,
                wrap: wrap,
                selection: inputSelection,
                editRevision: draftEditor.revision,
                undoManager: draftEditor.undoManager
            ) {
                Button("粘贴") { paste(into: &session.input) }
                Button("清空") { draftEditor.replaceInput("") }
            }
            VStack(spacing: 0) {
                if !session.translationConfigured {
                    HStack {
                        Text("尚未配置大模型翻译").font(.system(size: 12)).foregroundStyle(ToolTheme.secondary)
                        Button("打开设置", action: onOpenSettings).controlSize(.small)
                        Spacer()
                    }
                    .padding(10)
                    .background(ToolTheme.selection)
                }
                ToolEditorPane(
                    title: "译文",
                    text: .constant(session.output),
                    readOnly: true,
                    wrap: wrap,
                    stale: session.hasStaleResult,
                    editRevision: draftEditor.revision,
                    undoManager: draftEditor.undoManager
                ) {
                    Button("复制译文") { copy(session.output) }.disabled(!session.canCopy)
                }
            }
            .frame(minWidth: 300)
        }
    }

    var uuidBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本次结果 · \(session.output.split(separator: "\n").count) 条").font(.system(size: 12, weight: .semibold))
                if session.hasStaleResult { Text("结果已过期，请重新生成").font(.system(size: 11)).foregroundStyle(Theme.warning) }
                Spacer()
                Button("复制全部") { copy(session.output) }.disabled(!session.canCopy)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(ToolTheme.toolbar)

            ToolTheme.border.frame(height: 0.5)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(session.output.split(separator: "\n").enumerated()), id: \.offset) { index, value in
                        HStack(spacing: 14) {
                            Text(String(format: "%02d", index + 1)).foregroundStyle(Theme.tertiary).frame(width: 34)
                            Text(String(value)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Button("复制") { copy(String(value)) }.disabled(!session.canCopy).controlSize(.small)
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        ToolTheme.border.frame(height: 0.5)
                    }
                }
            }
        }
        .background(ToolTheme.editor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ToolTheme.border, lineWidth: 0.5))
        .padding(4)
    }
}
