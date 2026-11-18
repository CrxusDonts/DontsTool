import DontsToolCore
import SwiftUI

struct ShortcutFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ShortcutFormDraft
    let configuration: WebsiteShortcutConfiguration
    let save: (WebsiteShortcutConfiguration) throws -> Void
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var initial: ShortcutFormDraft?

    private var dirty: Bool { initial.map { draft != $0 } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isGroup ? "编辑网址分组" : "编辑系统").font(.system(size: 17, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Form {
                        TextField(draft.isGroup ? "前缀" : "系统简称", text: $draft.keyword)
                            .help(draft.isGroup ? "如 gh、ops，不含空格" : "如 订单、api")
                        TextField(draft.isGroup ? "分组名称" : "显示名称", text: $draft.name)
                        if draft.isGroup {
                            Text("例如 gh 代码仓库。配置 gh 后接管内置 GitHub 搜索。")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        } else {
                            LabeledContent("系统别名") {
                                aliasEditor($draft.aliases, height: 50)
                            }
                            Picker("网址类型", selection: $draft.addressMode) {
                                ForEach(ShortcutAddressMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("网址类型")
                            if draft.addressMode == .single {
                                TextField("网址", text: $draft.url, prompt: Text("https://orders.company.example"))
                            }
                        }
                    }
                    if !draft.isGroup {
                        if draft.addressMode == .environments { environmentFields }
                        Text("支持 HTTP/HTTPS 内网域名、IP 和端口；别名可选，每行一个。")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        pageFields
                    }
                }
                .padding(1)
            }
            .scrollBounceBehavior(.basedOnSize)
            .textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("保存", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 600, height: draft.isGroup ? 260 : 590).background(Theme.footerBase)
        .onAppear { if initial == nil { initial = draft } }
        .interactiveDismissDisabled()
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }

    private var environmentFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("省略环境时列出所有候选地址，需明确选择后才会打开。")
                .font(.caption).foregroundStyle(Theme.secondary)
            ForEach($draft.environments) { $environment in
                let environmentID = environment.id
                ShortcutEnvironmentEditor(draft: $environment) {
                    withAnimation(Motion.hoverEasing) {
                        draft.environments.removeAll { $0.id == environmentID }
                    }
                }
            }
            Button("添加环境", systemImage: "plus") {
                withAnimation(Motion.hoverEasing) { draft.environments.append(.init()) }
            }
            .controlSize(.small)
        }
    }

    private var pageFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("子页面").font(.system(size: 13, weight: .semibold))
                Text("可选 · \(draft.pages.count) 个").font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Button("添加子页面", systemImage: "plus") {
                    withAnimation(Motion.hoverEasing) { draft.pages.append(.init()) }
                }.controlSize(.small)
            }
            Text("例如 management 配置 /management，可用 ops avatar management prod 打开。")
                .font(.caption).foregroundStyle(Theme.secondary)
            ForEach($draft.pages) { $page in
                let pageID = page.id
                ShortcutPageEditor(
                    draft: $page,
                    environmentKeys: draft.addressMode == .environments ? draft.environments.map(\.key) : []
                ) {
                    withAnimation(Motion.hoverEasing) { draft.pages.removeAll { $0.id == pageID } }
                }
            }
        }
    }

    private func aliasEditor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.system(size: 12)).frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.controlBorder))
            .accessibilityLabel("系统别名，每行一个")
    }

    private func cancel() { if dirty { confirmDiscard = true } else { dismiss() } }

    private func commit() {
        do { try save(draft.proposal(in: configuration)); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct ShortcutEnvironmentEditor: View {
    @Binding var draft: ShortcutEnvironmentDraft
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.name.isEmpty ? (draft.key.isEmpty ? "新环境" : draft.key) : draft.name)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                Button("删除环境", action: remove).controlSize(.small)
                    .accessibilityLabel("删除\(draft.name.isEmpty ? draft.key : draft.name)环境")
            }
            Form {
                TextField("环境简称", text: $draft.key, prompt: Text("test、prod、staging"))
                TextField("显示名称", text: $draft.name, prompt: Text("可选，例如测试"))
                TextField("网址", text: $draft.url, prompt: Text("https://orders.test.company.example"))
                LabeledContent("环境别名") {
                    TextEditor(text: $draft.aliases).font(.system(size: 12)).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.controlBorder))
                        .accessibilityLabel("\(draft.key)环境别名，每行一个")
                }
            }
        }
        .padding(12)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.controlBorder))
    }
}

private struct ShortcutPageEditor: View {
    @Binding var draft: ShortcutPageDraft
    let environmentKeys: [String]
    let remove: () -> Void

    private var currentKeys: [String] {
        ShortcutPageDraft.environmentKeys(environmentKeys)
    }
    private var unknownKeys: [String] { draft.urls.keys.filter { !currentKeys.contains($0) }.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.name.isEmpty ? (draft.key.isEmpty ? "新子页面" : draft.key) : draft.name)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                Button("删除子页面", action: remove).controlSize(.small)
                    .accessibilityLabel("删除\(draft.name.isEmpty ? draft.key : draft.name)子页面")
            }
            Form {
                TextField("页面简称", text: $draft.key, prompt: Text("management"))
                TextField("显示名称", text: $draft.name, prompt: Text("管理后台"))
                TextField("路径或网址", text: $draft.path, prompt: Text("/management"))
                Text("以 / 开头，从站点根目录访问；也可填完整 HTTP(S) 网址")
                    .font(.caption).foregroundStyle(Theme.secondary)
                LabeledContent("页面别名") {
                    TextEditor(text: $draft.aliases).font(.system(size: 12)).frame(height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.controlBorder))
                        .accessibilityLabel("\(draft.key)子页面别名，每行一个")
                }
            }
            DisclosureGroup("指定环境的完整网址（可选）") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("留空使用上面的路径或网址。仅在某个环境使用特殊完整网址时填写。")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    if currentKeys.isEmpty && unknownKeys.isEmpty {
                        Text("先配置多个环境，即可按环境指定完整网址。")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    ForEach(currentKeys, id: \.self) { key in
                        LabeledContent(key) {
                            TextField("完整 HTTP(S) 网址", text: overrideBinding(key), prompt: Text("使用路径或网址"))
                                .accessibilityLabel("\(draft.key)子页面的\(key)环境完整网址")
                        }
                    }
                    if !unknownKeys.isEmpty {
                        Text("以下环境已移除或改名，请恢复环境简称，或明确删除这些指定网址后再保存。")
                            .font(.caption).foregroundStyle(Theme.warning)
                        ForEach(unknownKeys, id: \.self) { key in
                            HStack {
                                Text(key).font(.caption).frame(minWidth: 40, alignment: .leading)
                                TextField("完整 HTTP(S) 网址", text: overrideBinding(key))
                                    .accessibilityLabel("已移除环境\(key)的指定网址")
                                Button("删除") { draft.urls.removeValue(forKey: key) }.controlSize(.small)
                            }
                        }
                    }
                }.padding(.top, 8)
            }
            .font(.system(size: 11))
            if !unknownKeys.isEmpty {
                Text("有 \(unknownKeys.count) 个指定网址对应的环境不存在，请展开检查。")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .padding(12)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.controlBorder))
    }

    private func overrideBinding(_ key: String) -> Binding<String> {
        Binding(get: { draft.urls[key] ?? "" }, set: { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.urls.removeValue(forKey: key) }
            else { draft.urls[key] = value }
        })
    }
}
