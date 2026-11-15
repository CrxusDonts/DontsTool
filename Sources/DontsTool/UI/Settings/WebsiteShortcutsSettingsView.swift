import AppKit
import DontsToolCore
import SwiftUI
import UniformTypeIdentifiers

/// Native grouped settings. JSON uses a modal editor so tab switches cannot silently discard a draft.
struct WebsiteShortcutsSettingsView: View {
    @ObservedObject var store: WebsiteShortcutStore
    @State private var editing: ShortcutFormDraft?
    @State private var jsonDraft: ShortcutJSONDraft?
    @State private var pendingDeletion: ShortcutDeletion?
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("按分组、系统、子页面、环境打开网址，例如 ops avatar management prod。省略环境时列出全部候选地址。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                Button("添加分组", systemImage: "plus") { editing = .group() }
                Spacer()
                Button("JSON 配置") { jsonDraft = .init(text: store.editableJSON) }
                Button("导入…", action: importFile)
                Button("导出…", action: exportFile)
            }
            .controlSize(.small)
            if let loadError = store.loadError { message(loadError, color: Theme.warning) }
            if let error { message(error, color: .red) }
            if let notice { message(notice, color: Theme.success) }
            if store.configuration.groups.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("先添加一个网址分组", systemImage: "link.badge.plus")
                        .font(.system(size: 14, weight: .medium))
                    Text("例如 gh 管理代码仓库，ops 管理系统的测试和生产环境。配置仅保存在本机。")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Button("查看 JSON 示例") { jsonDraft = .init(text: Self.exampleJSON) }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(Array(store.configuration.groups.enumerated()), id: \.element.keyword) { index, group in
                groupView(group, index: index)
            }
            Text("gh 配置后接管内置 GitHub 搜索；json、kb 等其他内置前缀不可占用。")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .sheet(item: $editing) { draft in
            ShortcutFormSheet(draft: draft, configuration: store.configuration) { proposal in
                try store.save(proposal)
                notice = "已保存，启动器中即时生效"
                error = nil
            }
        }
        .sheet(item: $jsonDraft) { draft in
            ShortcutJSONSheet(original: draft.text, current: store.configuration) { config in
                try store.save(config)
                notice = "已保存 \(config.groups.count) 个分组、\(config.itemCount) 个系统、\(config.pageCount) 个子页面、\(config.addressCount) 个地址"
                error = nil
            }
        }
        .alert(item: $pendingDeletion) { deletion in
            Alert(title: Text(deletion.title), message: Text("保存后立即生效。可先导出 JSON 留作备份。"),
                primaryButton: .destructive(Text("删除")) { delete(deletion) }, secondaryButton: .cancel(Text("取消")))
        }
    }

    private func groupView(_ group: WebsiteShortcutGroup, index: Int) -> some View {
        SettingsGroup(caption: "\(group.keyword) · \(group.name)") {
            HStack(spacing: 8) {
                Text(group.keyword).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 5))
                Text("\(group.items.count) 个系统 · \(group.items.reduce(0) { $0 + $1.pages.count }) 个子页面").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("添加系统") { editing = .item(group: index) }.controlSize(.small)
                Menu {
                    Button("编辑分组") { editing = .group(index: index, value: group) }
                    Button("删除分组…", role: .destructive) {
                        pendingDeletion = .init(group: index, item: nil, title: "删除“\(group.name)”及其 \(group.items.count) 个系统？")
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help("分组操作")
                .accessibilityLabel("\(group.name)分组操作")
            }
            .padding(12)
            if group.items.isEmpty {
                SettingsDivider()
                Text("还没有系统，点击“添加系统”开始配置。")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            ForEach(Array(group.items.enumerated()), id: \.element.key) { offset, item in
                SettingsDivider()
                HStack(alignment: .top, spacing: 12) {
                    Text(item.key).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(6).frame(minWidth: 36)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.system(size: 13, weight: .medium))
                        if item.environments.isEmpty {
                            address(item.url)
                        } else {
                            ForEach(item.environments, id: \.key) { environment in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(environment.name.isEmpty ? environment.key : environment.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 4))
                                        .fixedSize()
                                    address(environment.url)
                                }
                            }
                        }
                        if !item.pages.isEmpty {
                            Text("\(item.pages.count) 个子页面：" + item.pages.map { $0.name.isEmpty ? $0.key : $0.name }.joined(separator: "、"))
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                        }
                        if !item.aliases.isEmpty {
                            Text("别名：" + item.aliases.joined(separator: "、"))
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("编辑") { editing = .item(group: index, index: offset, value: item) }
                        .controlSize(.small).accessibilityLabel("编辑\(item.name)")
                }
                .padding(12)
                .contextMenu {
                    Button("编辑系统") { editing = .item(group: index, index: offset, value: item) }
                    Button("删除系统…", role: .destructive) { pendingDeletion = .init(group: index, item: offset, title: "删除系统“\(item.name)”？") }
                }
            }
        }
    }

    private func address(_ url: String) -> some View {
        Text(url).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle).help(url)
            .textSelection(.enabled)
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color).textSelection(.enabled)
    }

    private func delete(_ deletion: ShortcutDeletion) {
        var config = store.configuration
        if let item = deletion.item { config.groups[deletion.group].items.remove(at: item) }
        else { config.groups.remove(at: deletion.group) }
        do { try store.save(config); notice = "已删除"; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.prompt = "载入配置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: WebsiteShortcutConfiguration.maximumBytes + 1) ?? Data()
            guard data.count <= WebsiteShortcutConfiguration.maximumBytes else { throw ActionError.invalidInput("配置文件不能超过 1 MiB") }
            guard let text = String(data: data, encoding: .utf8) else { throw ActionError.invalidInput("请选择 UTF-8 编码的 JSON 文件") }
            // Open a reviewable draft; importing never overwrites the saved configuration immediately.
            jsonDraft = .init(text: text)
        } catch { self.error = error.localizedDescription }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "dontstool-websites.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(store.editableJSON.utf8).write(to: url, options: .atomic); notice = "配置已导出"; error = nil }
        catch { self.error = error.localizedDescription }
    }

    static let exampleJSON = """
    {
      "version": 3,
      "groups": [
        {
          "keyword": "ops",
          "name": "业务系统",
          "items": [
            {
              "key": "avatar",
              "name": "Avatar 系统",
              "aliases": ["头像系统"],
              "environments": [
                { "key": "test", "name": "测试", "url": "https://avatar.test.company.example", "aliases": ["测试环境"] },
                { "key": "prod", "name": "生产", "url": "https://avatar.company.example", "aliases": ["线上"] }
              ],
              "pages": [
                { "key": "management", "name": "管理后台", "path": "/management", "aliases": ["managment", "管理"] },
                { "key": "reports", "name": "报表", "path": "/reports", "urls": { "prod": "https://reports.company.example/dashboard" } }
              ]
            }
          ]
        }
      ]
    }
    """
}

private struct ShortcutJSONDraft: Identifiable {
    let id = UUID()
    let text: String
}
private struct ShortcutDeletion: Identifiable {
    let id = UUID()
    let group: Int
    let item: Int?
    let title: String
}
enum ShortcutAddressMode: String, CaseIterable, Identifiable, Sendable {
    case single = "单个网址"
    case environments = "多个环境"
    var id: Self { self }
}

struct ShortcutEnvironmentDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    var key: String = ""
    var name: String = ""
    var url: String = ""
    var aliases: String = ""

    static let startingRows: [Self] = [
        .init(key: "test", name: "测试"),
        .init(key: "prod", name: "生产"),
    ]
}

struct ShortcutPageDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    var key: String = ""
    var name: String = ""
    var path: String = ""
    var aliases: String = ""
    var urls: [String: String] = [:]

    static func environmentKeys(_ keys: [String]) -> [String] {
        Array(Set(keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
    }
}

struct ShortcutFormDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    var groupIndex: Int?
    var itemIndex: Int?
    var isGroup: Bool
    var keyword: String = ""
    var name: String = ""
    var url: String = ""
    var aliases: String = ""
    var addressMode: ShortcutAddressMode = .single
    var environments: [ShortcutEnvironmentDraft] = ShortcutEnvironmentDraft.startingRows
    var pages: [ShortcutPageDraft] = []

    static func group(index: Int? = nil, value: WebsiteShortcutGroup? = nil) -> Self {
        .init(groupIndex: index, isGroup: true, keyword: value?.keyword ?? "", name: value?.name ?? "")
    }

    static func item(group: Int, index: Int? = nil, value: WebsiteShortcut? = nil) -> Self {
        let environments = value?.environments ?? []
        return .init(
            groupIndex: group, itemIndex: index, isGroup: false,
            keyword: value?.key ?? "", name: value?.name ?? "", url: value?.url ?? "",
            aliases: value?.aliases.joined(separator: "\n") ?? "",
            addressMode: environments.isEmpty ? .single : .environments,
            environments: environments.isEmpty ? ShortcutEnvironmentDraft.startingRows : environments.map {
                .init(key: $0.key, name: $0.name, url: $0.url, aliases: $0.aliases.joined(separator: "\n"))
            },
            pages: (value?.pages ?? []).map {
                .init(key: $0.key, name: $0.name, path: $0.path, aliases: $0.aliases.joined(separator: "\n"), urls: $0.urls)
            }
        )
    }

    func proposal(in configuration: WebsiteShortcutConfiguration) -> WebsiteShortcutConfiguration {
        var config = configuration
        if isGroup {
            if let index = groupIndex {
                config.groups[index].keyword = keyword; config.groups[index].name = name
            } else { config.groups.append(.init(keyword: keyword, name: name)) }
        } else if let index = groupIndex {
            let environments: [WebsiteShortcutEnvironment] = addressMode == .environments ? self.environments.map {
                .init(key: $0.key, name: $0.name, url: $0.url, aliases: aliases($0.aliases))
            } : []
            if !pages.isEmpty { config.version = max(config.version, 3) }
            else if addressMode == .environments { config.version = max(config.version, 2) }
            let item = WebsiteShortcut(
                key: keyword, name: name,
                url: addressMode == .single ? url : "", aliases: aliases(self.aliases),
                environments: environments,
                pages: pages.map { .init(key: $0.key, name: $0.name, path: $0.path, aliases: aliases($0.aliases), urls: $0.urls) }
            )
            if let offset = itemIndex { config.groups[index].items[offset] = item }
            else { config.groups[index].items.append(item) }
        }
        return config
    }

    private func aliases(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

}

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

private struct ShortcutJSONSheet: View {
    @Environment(\.dismiss) private var dismiss
    let original: String
    let current: WebsiteShortcutConfiguration
    let save: (WebsiteShortcutConfiguration) throws -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var validated: WebsiteShortcutConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("JSON 配置").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("格式化") {
                    do { text = try WebsiteShortcutConfiguration.decode(text).json(); validate() }
                    catch { self.error = error.localizedDescription }
                }.controlSize(.small)
            }
            Text("保存将替换全部网址配置。当前：\(current.groups.count) 个分组、\(current.itemCount) 个系统、\(current.pageCount) 个子页面、\(current.addressCount) 个地址。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            ToolTextEditor(text: $text, json: true, label: "网址 JSON 配置")
                .padding(8).background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.controlBorder))
                .accessibilityLabel("网址 JSON 配置")
                .onChange(of: text) { _, _ in validate() }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3) }
            else if let validated {
                Text("校验通过：\(validated.groups.count) 个分组、\(validated.itemCount) 个系统、\(validated.pageCount) 个子页面、\(validated.addressCount) 个地址")
                    .font(.system(size: 12)).foregroundStyle(Theme.success)
            }
            HStack {
                Spacer()
                Button("取消") { if text != original { confirmDiscard = true } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                Button("保存配置") {
                    do { try save(WebsiteShortcutConfiguration.decode(text)); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(validated == nil)
            }
        }
        .padding(20).frame(width: 660, height: 520).background(Theme.footerBase)
        .onAppear { text = original; validate() }
        .interactiveDismissDisabled()
        .confirmationDialog("放弃未保存的 JSON 修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }
    private func validate() {
        do { validated = try WebsiteShortcutConfiguration.decode(text); error = nil }
        catch { validated = nil; self.error = error.localizedDescription }
    }
}
