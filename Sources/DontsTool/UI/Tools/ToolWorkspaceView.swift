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
    @State var selectedDifference: Int?
    @State var wrap = true
    @State private var feedback: String?
    @State private var feedbackVersion = UUID()
    @State var inputSelection: EditorSelection?
    @State var leftSelection: EditorSelection?
    @State var rightSelection: EditorSelection?

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
                    .padding(.vertical, 3.5)
                    .background(document.isPinned ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(document.isPinned ? ToolTheme.ink : ToolTheme.secondary)
            .help(document.isPinned ? "取消窗口置顶" : "保持在其他普通窗口前面")
            .accessibilityValue(document.isPinned ? "已开启" : "已关闭")

            Button { renaming = true } label: {
                Label("重命名", systemImage: "pencil")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
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
                .foregroundStyle(active ? ToolTheme.ink : ToolTheme.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(active ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Theme.controlBorder : Color.clear, lineWidth: 0.5))
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
        } else { inputSelection = EditorSelection(range: range) }
    }

    func paste(into text: inout String) { if let value = NSPasteboard.general.string(forType: .string) { text = value } }

    func copy(_ text: String) {
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
