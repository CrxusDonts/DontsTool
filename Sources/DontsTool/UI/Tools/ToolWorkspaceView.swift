import AppKit
import DontsToolCore
import SwiftUI

struct ToolWorkspaceView: View {
    @ObservedObject var document: ToolDocument
    @ObservedObject var documents: ToolDocumentStore
    @ObservedObject var draftEditor: ToolDraftEditor
    @ObservedObject var session: ToolSession
    var onOpenSettings: () -> Void

    init(document: ToolDocument, documents: ToolDocumentStore, draftEditor: ToolDraftEditor, onOpenSettings: @escaping () -> Void) {
        self.document = document; self.documents = documents; self.session = document.session; self.draftEditor = draftEditor
        self.onOpenSettings = onOpenSettings
    }

    @State private var renaming = false
    @State private var selectedDifference: Int?
    @State private var wrap = true
    @State private var feedback: String?
    @State private var feedbackVersion = UUID()
    @State private var inputSelection: EditorSelection?
    @State private var leftSelection: EditorSelection?
    @State private var rightSelection: EditorSelection?

    var body: some View {
        VStack(spacing: 0) {
            documentBar
            ToolTheme.border.frame(height: 0.5)
            optionsBar
            ToolTheme.border.frame(height: 0.5)

            if session.pendingRequest != nil {
                HStack(spacing: 10) {
                    Text("启动器带来了新内容，是否替换当前输入？").font(.system(size: 12))
                    Spacer()
                    Button("保留当前内容") { session.resolvePending(useNew: false) }
                    Button("使用新内容") { session.resolvePending(useNew: true) }.buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(ToolTheme.selection)
                ToolTheme.border.frame(height: 0.5)
            }

            if let error = session.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    if session.errorRange != nil { Button("定位错误") { locateError() }.controlSize(.small) }
                    if session.kind == .translation { Button("打开设置", action: onOpenSettings).controlSize(.small) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.warning.opacity(0.08))
                ToolTheme.border.frame(height: 0.5)
            }

            Group {
                switch session.kind {
                case .json: jsonBody
                case .uuid: uuidBody
                case .base64, .url: textEditorBody
                case .hash, .timestamp: compactUtilityBody
                case .translation: translationBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(6)
            .background(ToolTheme.workspace)

            ToolTheme.border.frame(height: 0.5)
            statusBar
        }
        .background(ToolTheme.workspace)
        .foregroundStyle(ToolTheme.ink)
        .tint(ToolTheme.accent)
        .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.14), value: session.errorMessage != nil)
        .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.14), value: feedback != nil)
    }

    private var documentBar: some View {
        HStack(spacing: 10) {
            if session.kind == .json {
                Picker("工作模式", selection: $session.comparing) {
                    Text("编辑").tag(false); Text("对比").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 124)
            } else {
                Text(session.kind.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToolTheme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { document.isPinned.toggle() } label: {
                Label(document.isPinned ? "已置顶" : "置顶", systemImage: document.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(document.isPinned ? Theme.accentFill : Theme.controlFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(document.isPinned ? Theme.accentBorder : Theme.controlBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(document.isPinned ? ToolTheme.accent : ToolTheme.secondary)
            .help(document.isPinned ? "取消窗口置顶" : "保持在其他普通窗口前面")
            .accessibilityValue(document.isPinned ? "已开启" : "已关闭")

            Button { renaming = true } label: {
                Label("重命名", systemImage: "pencil")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.controlFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ToolTheme.secondary)
            .help("重命名当前窗口")
            .popover(isPresented: $renaming) {
                ToolNameEditor(label: "窗口名称", current: document.title, onCancel: { renaming = false }) { title in
                    documents.rename(document.id, to: title); renaming = false
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(ToolTheme.shell)
    }

    private var optionsBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { options }.padding(.vertical, 6)
            }
            if session.isRunning {
                ProgressView().controlSize(.small)
                Button("取消") { session.cancel() }
            } else if !session.editsTextInPlace {
                Button(session.primaryTitle) { draftEditor.run() }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(ToolTheme.onAccent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(ToolTheme.toolbar)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(feedback != nil ? Theme.success : ToolTheme.accent)
                .frame(width: 6, height: 6)
            Text(feedback ?? session.status)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if session.kind != .uuid {
                Text(session.kind == .json && session.comparing
                     ? "UTF-8 · 左 \(session.compareLeft.utf8.count) / 右 \(session.compareRight.utf8.count) 字节"
                     : "UTF-8 · \(session.input.utf8.count) 字节")
                .foregroundStyle(Theme.tertiary)
                Toggle("自动换行", isOn: $wrap).toggleStyle(.checkbox)
            }
            Text("⌘↩ \(session.primaryTitle)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(ToolTheme.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(ToolTheme.shell)
    }

    @ViewBuilder private var options: some View {
        switch session.kind {
        case .json:
            if session.comparing {
                Button("交换左右") { draftEditor.swapComparison() }
            } else {
                transformationButton("格式化", mode: "format")
                transformationButton("压缩", mode: "minify")
                transformationButton("转义", mode: "escape")
                transformationButton("去转义", mode: "unescape")
                if session.mode == "unescape" { Toggle("无外层引号", isOn: $session.bare).toggleStyle(.checkbox) }
            }
        case .base64, .url:
            transformationButton("编码", mode: "encode")
            transformationButton("解码", mode: "decode")
            if session.kind == .base64 { Toggle("URL-safe", isOn: $session.urlSafe).toggleStyle(.checkbox) }
            else { Toggle("表单模式（+ 代表空格）", isOn: $session.form).toggleStyle(.checkbox) }
        case .hash:
            Picker("算法", selection: $session.mode) {
                ForEach(HashAlgorithm.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            Text("按 UTF-8 原文计算，保留空白与换行").font(.system(size: 11)).foregroundStyle(ToolTheme.secondary)
        case .uuid:
            Text("数量").font(.system(size: 11.5))
            TextField("1–1000", text: $session.uuidCount).frame(width: 64).textFieldStyle(.roundedBorder).accessibilityLabel("UUID 数量")
            Toggle("大写", isOn: $session.uppercase).toggleStyle(.checkbox)
            Toggle("保留连字符", isOn: $session.hyphens).toggleStyle(.checkbox)
        case .timestamp:
            Picker("输入单位", selection: $session.unit) {
                ForEach(TimestampUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 176)
            Picker("时区", selection: $session.utc) {
                Text("当前时区").tag(false); Text("UTC").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            Button("当前时间") { draftEditor.replaceInput(""); draftEditor.run() }
        case .translation:
            Picker("译为", selection: $session.target) {
                Text("简体中文").tag("zh-Hans"); Text("繁體中文").tag("zh-Hant"); Text("English").tag("en")
                Text("日本語").tag("ja"); Text("한국어").tag("ko"); Text("Français").tag("fr"); Text("Deutsch").tag("de")
                if !["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de"].contains(session.target) { Text(session.target).tag(session.target) }
            }
            .frame(width: 160)
            Button("翻译设置", action: onOpenSettings)
            Button("网页翻译") { openWebTranslation() }
        }
    }

    private func transformationButton(_ title: String, mode: String) -> some View {
        let active = session.mode == mode
        return Button {
            session.mode = mode
            draftEditor.run()
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? ToolTheme.accent : ToolTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(active ? Theme.accentFill : Theme.controlFill, in: Capsule())
                .overlay(Capsule().strokeBorder(active ? Theme.accentBorder : Theme.controlBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(active ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .disabled(session.isRunning)
    }

    private var textEditorBody: some View {
        ToolEditorPane(
            title: session.kind == .json ? "JSON" : "内容",
            text: $session.input,
            json: session.kind == .json,
            wrap: wrap,
            selection: inputSelection,
            active: session.kind != .json || !session.comparing,
            editRevision: draftEditor.revision,
            undoManager: draftEditor.undoManager
        ) {
            Button("粘贴") { paste(into: &session.input) }
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

    private var compactUtilityBody: some View {
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

    private var translationBody: some View {
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

    // Keep both native editor sets alive so mode switches preserve selection and undo targets.
    private var jsonBody: some View {
        ZStack {
            jsonComparisonBody.opacity(session.comparing ? 1 : 0).allowsHitTesting(session.comparing).accessibilityHidden(!session.comparing)
            jsonEditBody.opacity(session.comparing ? 0 : 1).allowsHitTesting(!session.comparing).accessibilityHidden(session.comparing)
        }
    }

    private var jsonComparisonBody: some View {
        VSplitView {
            HSplitView {
                ToolEditorPane(
                    title: document.leftTitle,
                    text: $session.compareLeft,
                    json: true,
                    wrap: wrap,
                    selection: leftSelection,
                    name: $document.leftTitle,
                    active: session.comparing,
                    editRevision: draftEditor.revision,
                    undoManager: draftEditor.undoManager
                ) {
                    Button("粘贴") { paste(into: &session.compareLeft) }
                    Button("清空") { session.compareLeft = "" }
                }
                ToolEditorPane(
                    title: document.rightTitle,
                    text: $session.compareRight,
                    json: true,
                    wrap: wrap,
                    selection: rightSelection,
                    name: $document.rightTitle,
                    active: session.comparing,
                    editRevision: draftEditor.revision,
                    undoManager: draftEditor.undoManager
                ) {
                    Button("粘贴") { paste(into: &session.compareRight) }
                    Button("清空") { session.compareRight = "" }
                }
            }
            .frame(minHeight: 200)

            differences
                .frame(minHeight: 130, idealHeight: 200)
                .background(ToolTheme.editor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ToolTheme.border, lineWidth: 0.5))
                .padding(4)
        }
    }

    private var jsonEditBody: some View { textEditorBody }

    private var differences: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("结构差异").fontWeight(.semibold)
                Spacer()
                Text(session.comparison.map { "\($0.total) 项" } ?? "尚未对比").foregroundStyle(ToolTheme.secondary)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(ToolTheme.toolbar)

            ToolTheme.border.frame(height: 0.5)

            if session.comparison != nil && session.hasStaleResult {
                Text("旧对比结果已过期，请重新对比")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }

            if let comparison = session.comparison {
                if comparison.total == 0 {
                    Text("无结构差异").foregroundStyle(ToolTheme.secondary).padding(16)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(comparison.differences) { difference in
                            Button {
                                selectedDifference = difference.id
                                if let range = difference.leftRange { leftSelection = EditorSelection(range: range) }
                                if let range = difference.rightRange { rightSelection = EditorSelection(range: range) }
                            } label: {
                                HStack(spacing: 12) {
                                    Text(difference.kind.rawValue)
                                        .foregroundStyle(difference.kind == .added ? Theme.success : difference.kind == .removed ? Theme.warning : ToolTheme.accent)
                                        .frame(width: 36)
                                    Text(difference.path).frame(width: 180, alignment: .leading)
                                    Text(difference.left).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right").foregroundStyle(Theme.tertiary)
                                    Text(difference.right).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(selectedDifference == difference.id ? ToolTheme.selection : Color.clear)
                            .disabled(!session.isFresh)

                            ToolTheme.border.frame(height: 0.5)
                        }
                    }
                }
            } else {
                Text("编辑两侧 JSON 后点击「对比」。对象忽略字段顺序，数组按索引比较。")
                    .font(.system(size: 12))
                    .foregroundStyle(ToolTheme.secondary)
                    .padding(16)
            }
            Spacer(minLength: 0)
        }
    }

    private var uuidBody: some View {
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

    private func locateError() {
        guard let range = session.errorRange else { return }
        if session.comparing {
            if session.errorSide == "右侧" { rightSelection = EditorSelection(range: range) }
            else { leftSelection = EditorSelection(range: range) }
        } else { inputSelection = EditorSelection(range: range) }
    }

    private func paste(into text: inout String) { if let value = NSPasteboard.general.string(forType: .string) { text = value } }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        feedback = "已复制"; let version = UUID(); feedbackVersion = version
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if feedbackVersion == version { feedback = nil }
        }
    }

    private func openWebTranslation() {
        var components = URLComponents(string: "https://translate.google.com/")!
        components.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: session.target == "zh-Hans" ? "zh-CN" : session.target == "zh-Hant" ? "zh-TW" : session.target),
            URLQueryItem(name: "text", value: session.input),
            URLQueryItem(name: "op", value: "translate")
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
