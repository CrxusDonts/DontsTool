import AppKit
import DontsToolCore
import SwiftUI

enum JSONViewMode: Hashable {
    case code
    case tree
    case compare
}

struct ToolWorkspaceView: View {
    @ObservedObject var document: ToolDocument
    @ObservedObject var documents: ToolDocumentStore
    @ObservedObject var draftEditor: ToolDraftEditor
    @ObservedObject var session: ToolSession
    var onOpenSettings: () -> Void

    init(document: ToolDocument, documents: ToolDocumentStore, draftEditor: ToolDraftEditor, onOpenSettings: @escaping () -> Void) {
        self.document = document
        self.documents = documents
        self.session = document.session
        self.draftEditor = draftEditor
        self.onOpenSettings = onOpenSettings
    }

    @State private var renaming = false
    @State var selectedDifference: Int?
    @State var wrap = true
    @State private var feedback: String?
    @State private var feedbackVersion = UUID()
    @State var inputSelection: EditorSelection?
    @State var leftSelection: EditorSelection?
    @State var rightSelection: EditorSelection?

    @State var jsonViewMode: JSONViewMode = .code
    @State var showJSONOutline = true
    @State var jsonAnalysis: JSONAnalysis = .empty
    @State var leftAnalysis: JSONAnalysis = .empty
    @State var rightAnalysis: JSONAnalysis = .empty
    @State var cursorPosition = EditorCursorPosition(line: 1, column: 1, utf16Offset: 0)
    @State var codeFoldCommand: EditorFoldCommand?
    @State var compareFoldCommand: EditorFoldCommand?
    @State var diffFilter: JSONDifference.Kind? = nil

    var filteredDifferences: [JSONDifference] {
        guard let comparison = session.comparison else { return [] }
        guard let diffFilter else { return comparison.differences }
        return comparison.differences.filter { $0.kind == diffFilter }
    }

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
        .onAppear {
            if session.kind == .json {
                jsonViewMode = session.comparing ? .compare : .code
            }
        }
        .onChange(of: jsonViewMode) { _, newValue in
            guard session.kind == .json else { return }
            let nextComparing = (newValue == .compare)
            if session.comparing != nextComparing {
                session.comparing = nextComparing
            }
        }
        .onChange(of: session.comparing) { _, newValue in
            guard session.kind == .json else { return }
            if newValue && jsonViewMode != .compare {
                jsonViewMode = .compare
            } else if !newValue && jsonViewMode == .compare {
                jsonViewMode = .code
            }
        }
        .onChange(of: session.comparison?.total) { _, _ in
            selectedDifference = nil
            diffFilter = nil
        }
        .task(id: session.input) {
            guard session.kind == .json else { return }
            let source = session.input
            if source.utf8.count > 8_192 {
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { JSONInspector.analyze(source) }.value
            guard !Task.isCancelled else { return }
            jsonAnalysis = result
        }
        .task(id: session.compareLeft) {
            guard session.kind == .json else { return }
            let source = session.compareLeft
            if source.utf8.count > 8_192 {
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { JSONInspector.analyze(source) }.value
            guard !Task.isCancelled else { return }
            leftAnalysis = result
        }
        .task(id: session.compareRight) {
            guard session.kind == .json else { return }
            let source = session.compareRight
            if source.utf8.count > 8_192 {
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { JSONInspector.analyze(source) }.value
            guard !Task.isCancelled else { return }
            rightAnalysis = result
        }
    }

    private var documentBar: some View {
        HStack(spacing: 10) {
            if session.kind == .json {
                jsonTopStatusPill
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("工作模式", selection: $jsonViewMode) {
                    Text("代码").tag(JSONViewMode.code)
                    Text("树形").tag(JSONViewMode.tree)
                    Text("对比").tag(JSONViewMode.compare)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 196)

                HStack(spacing: 6) {
                    if jsonViewMode == .code {
                        ToolQuietButton(
                            title: "大纲",
                            systemImage: "sidebar.right",
                            active: showJSONOutline
                        ) {
                            showJSONOutline.toggle()
                        }
                        .help("显示或隐藏右侧结构树大纲")
                    }
                    topBarWindowButtons
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(session.kind.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToolTheme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                topBarWindowButtons
            }
        }
        .padding(.horizontal, 14)
        .frame(height: session.kind == .json ? 40 : 36)
        .background(ToolTheme.shell)
    }

    @ViewBuilder
    private var topBarWindowButtons: some View {
        ToolQuietButton(
            title: document.isPinned ? "已置顶" : "置顶",
            systemImage: document.isPinned ? "pin.fill" : "pin",
            active: document.isPinned
        ) {
            document.isPinned.toggle()
        }
        .help(document.isPinned ? "取消窗口置顶" : "保持在其他普通窗口前面")
        .accessibilityValue(document.isPinned ? "已开启" : "已关闭")

        ToolQuietButton(title: "重命名", systemImage: "pencil") {
            renaming = true
        }
        .help("重命名当前窗口")
        .popover(isPresented: $renaming) {
            ToolNameEditor(label: "窗口名称", current: document.title, onCancel: { renaming = false }) { title in
                documents.rename(document.id, to: title)
                renaming = false
            }
        }
    }

    @ViewBuilder
    private var jsonTopStatusPill: some View {
        if jsonViewMode == .compare {
            if let comparison = session.comparison, session.isFresh {
                JSONStatusPill(
                    text: comparison.total == 0 ? "结构完全一致" : "发现 \(comparison.total) 处差异",
                    tone: comparison.total == 0 ? .valid : .warning
                )
            } else if case .invalid(_, let line, let col, let range) = leftAnalysis.validation {
                JSONStatusPill(text: "左侧第 \(line):\(col) 行语法错误", tone: .error, clickable: true) {
                    leftSelection = EditorSelection(range: range)
                }
            } else if case .invalid(_, let line, let col, let range) = rightAnalysis.validation {
                JSONStatusPill(text: "右侧第 \(line):\(col) 行语法错误", tone: .error, clickable: true) {
                    rightSelection = EditorSelection(range: range)
                }
            } else {
                JSONStatusPill(text: "结构对比模式", tone: .neutral)
            }
        } else {
            switch jsonAnalysis.validation {
            case .empty:
                JSONStatusPill(text: jsonAnalysis.validation.badgeText, tone: .neutral)
            case .valid:
                JSONStatusPill(text: jsonAnalysis.validation.badgeText, tone: .valid)
            case .invalid(_, _, _, let range):
                JSONStatusPill(text: jsonAnalysis.validation.badgeText, tone: .error, clickable: true) {
                    jsonViewMode = .code
                    inputSelection = EditorSelection(range: range)
                }
                .help("点击定位语法错误位置")
            }
        }
    }

    private var optionsBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { options }.padding(.vertical, 6)
            }

            if session.kind == .json {
                jsonTrailingToolbarActions
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
        .frame(height: 40)
        .background(ToolTheme.toolbar)
    }

    @ViewBuilder
    private var jsonTrailingToolbarActions: some View {
        if jsonViewMode == .compare {
            let diffs = filteredDifferences
            if !diffs.isEmpty && session.isFresh {
                diffStepNavigator(diffs: diffs)
            }
        } else {
            ToolQuietButton(title: "粘贴", systemImage: "doc.on.clipboard") {
                pasteFormattedJSON()
            }
            ToolQuietButton(title: "复制", systemImage: "doc.on.doc", disabled: session.input.isEmpty) {
                copy(session.input)
            }
            ToolQuietButton(title: "清空", systemImage: "trash", disabled: session.input.isEmpty) {
                draftEditor.replaceInput("")
            }
            Menu {
                Button("送到对比左侧") { draftEditor.replaceComparisonSide(session.input, right: false) }
                Button("送到对比右侧") { draftEditor.replaceComparisonSide(session.input, right: true) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10.5, weight: .medium))
                    Text("送入对比")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(ToolTheme.secondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ToolTheme.border, lineWidth: 0.5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func diffStepNavigator(diffs: [JSONDifference]) -> some View {
        let currentIndex = diffs.firstIndex { $0.id == selectedDifference }
        let labelText = currentIndex.map { "\($0 + 1) / \(diffs.count)" } ?? "0 / \(diffs.count)"
        return HStack(spacing: 4) {
            ToolQuietButton(title: "", systemImage: "chevron.up") {
                stepDifference(in: diffs, delta: -1)
            }
            .help("上一处差异")

            Text(labelText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(ToolTheme.secondary)
                .frame(minWidth: 44)

            ToolQuietButton(title: "", systemImage: "chevron.down") {
                stepDifference(in: diffs, delta: 1)
            }
            .help("下一处差异")
        }
        .padding(.horizontal, 4)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ToolTheme.border, lineWidth: 0.5))
    }

    private func stepDifference(in diffs: [JSONDifference], delta: Int) {
        guard !diffs.isEmpty else { return }
        if let currentIndex = diffs.firstIndex(where: { $0.id == selectedDifference }) {
            let nextIndex = ((currentIndex + delta) % diffs.count + diffs.count) % diffs.count
            selectDifference(diffs[nextIndex])
        } else {
            selectDifference(delta >= 0 ? diffs[0] : diffs[diffs.count - 1])
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if feedback != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.success)
            }
            Text(feedback ?? session.status)
                .foregroundStyle(ToolTheme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if session.kind != .uuid {
                if session.kind == .json && jsonViewMode == .code {
                    Text("行 \(cursorPosition.line), 列 \(cursorPosition.column)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ToolTheme.secondary)
                    Text("·").foregroundStyle(Theme.tertiary)
                }
                Text(session.kind == .json && session.comparing
                     ? "UTF-8 · 左 \(session.compareLeft.utf8.count) / 右 \(session.compareRight.utf8.count) 字节"
                     : "UTF-8 · \(session.input.utf8.count) 字节")
                    .foregroundStyle(Theme.tertiary)
                Toggle("自动换行", isOn: $wrap).toggleStyle(.checkbox)
            }
            Text("⌘↩ \(session.primaryTitle)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(ToolTheme.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ToolTheme.border, lineWidth: 0.5))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(ToolTheme.shell)
    }

    @ViewBuilder private var options: some View {
        switch session.kind {
        case .json:
            if jsonViewMode == .compare {
                ToolQuietButton(title: "交换左右", systemImage: "arrow.left.arrow.right") {
                    draftEditor.swapComparison()
                }
                ToolQuietButton(title: "格式化两侧", systemImage: "text.alignleft") {
                    _ = try? draftEditor.formatComparisonBoth()
                }
                ToolToolbarDivider()
                ToolQuietButton(title: "全部折叠", systemImage: "chevron.right") {
                    compareFoldCommand = EditorFoldCommand(action: .collapseAll)
                }
                ToolQuietButton(title: "全部展开", systemImage: "chevron.down") {
                    compareFoldCommand = EditorFoldCommand(action: .expandAll)
                }
            } else {
                transformationButton("格式化", mode: "format")
                transformationButton("压缩", mode: "minify")
                transformationButton("转义", mode: "escape")
                transformationButton("去转义", mode: "unescape")
                if session.mode == "unescape" {
                    Toggle("无外层引号", isOn: $session.bare).toggleStyle(.checkbox)
                }
                if jsonViewMode == .code {
                    ToolToolbarDivider()
                    ToolQuietButton(title: "全部折叠", systemImage: "chevron.right") {
                        codeFoldCommand = EditorFoldCommand(action: .collapseAll)
                    }
                    ToolQuietButton(title: "全部展开", systemImage: "chevron.down") {
                        codeFoldCommand = EditorFoldCommand(action: .expandAll)
                    }
                    Menu {
                        Button("展开到第 1 层（仅顶层键）") {
                            codeFoldCommand = EditorFoldCommand(action: .collapseToDepth(1))
                        }
                        Button("展开到第 2 层") {
                            codeFoldCommand = EditorFoldCommand(action: .collapseToDepth(2))
                        }
                        Button("展开到第 3 层") {
                            codeFoldCommand = EditorFoldCommand(action: .collapseToDepth(3))
                        }
                        Divider()
                        Button("全部展开") {
                            codeFoldCommand = EditorFoldCommand(action: .expandAll)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 10.5))
                            Text("按层级")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(ToolTheme.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ToolTheme.border, lineWidth: 0.5))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
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
            Button("模型服务", action: onOpenSettings)
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
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? ToolTheme.accent : ToolTheme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(active ? Theme.accentFill : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Theme.accentBorder : Color.clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(active ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .disabled(session.isRunning)
    }

    private func locateError() {
        guard let range = session.errorRange else { return }
        if session.comparing {
            if session.errorSide == "右侧" { rightSelection = EditorSelection(range: range) }
            else { leftSelection = EditorSelection(range: range) }
        } else {
            if session.kind == .json { jsonViewMode = .code }
            inputSelection = EditorSelection(range: range)
        }
    }

    func paste(into text: inout String) { if let value = NSPasteboard.general.string(forType: .string) { text = value } }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback = "已复制"
        let version = UUID()
        feedbackVersion = version
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
