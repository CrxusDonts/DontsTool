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
            Text("自定义前缀和项目简称，例如 gh a。回车后用默认浏览器打开。")
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
                    Text("例如 gh 管理代码仓库，env 管理测试环境。网址与配置仅保存在本机。")
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
                notice = "已保存 \(config.groups.count) 个分组、\(config.itemCount) 个网址"
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
                Text("\(group.items.count) 个网址").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("添加网址") { editing = .item(group: index) }.controlSize(.small)
                Menu {
                    Button("编辑分组") { editing = .group(index: index, value: group) }
                    Button("删除分组…", role: .destructive) {
                        pendingDeletion = .init(group: index, item: nil, title: "删除“\(group.name)”及其 \(group.items.count) 个网址？")
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help("分组操作")
                .accessibilityLabel("\(group.name)分组操作")
            }
            .padding(12)
            if group.items.isEmpty {
                SettingsDivider()
                Text("还没有网址，点击“添加网址”开始配置。")
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
                        Text(item.url).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle).help(item.url)
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
                    Button("编辑网址") { editing = .item(group: index, index: offset, value: item) }
                    Button("删除网址…", role: .destructive) { pendingDeletion = .init(group: index, item: offset, title: "删除网址“\(item.name)”？") }
                }
            }
        }
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
      "version": 1,
      "groups": [
        {
          "keyword": "gh",
          "name": "代码仓库",
          "items": [
            { "key": "a", "name": "项目 A", "url": "https://git.company.example/team/project-a", "aliases": ["订单服务"] },
            { "key": "b", "name": "项目 B", "url": "https://git.company.example/team/project-b" }
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
private struct ShortcutFormDraft: Identifiable {
    let id = UUID()
    var groupIndex: Int?
    var itemIndex: Int?
    var isGroup: Bool
    var keyword: String = ""
    var name: String = ""
    var url: String = ""
    var aliases: String = ""
    static func group(index: Int? = nil, value: WebsiteShortcutGroup? = nil) -> Self {
        .init(groupIndex: index, isGroup: true, keyword: value?.keyword ?? "", name: value?.name ?? "")
    }
    static func item(group: Int, index: Int? = nil, value: WebsiteShortcut? = nil) -> Self {
        .init(groupIndex: group, itemIndex: index, isGroup: false, keyword: value?.key ?? "", name: value?.name ?? "", url: value?.url ?? "", aliases: value?.aliases.joined(separator: "\n") ?? "")
    }
}

private struct ShortcutFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ShortcutFormDraft
    let configuration: WebsiteShortcutConfiguration
    let save: (WebsiteShortcutConfiguration) throws -> Void
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var initial: ShortcutFormDraft?

    private var dirty: Bool {
        guard let initial else { return false }
        return draft.keyword != initial.keyword || draft.name != initial.name || draft.url != initial.url || draft.aliases != initial.aliases
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isGroup ? "编辑网址分组" : "编辑网址").font(.system(size: 17, weight: .semibold))
            Form {
                TextField(draft.isGroup ? "前缀" : "项目简称", text: $draft.keyword)
                    .help(draft.isGroup ? "如 gh、env，不含空格" : "如 a、api、dev")
                TextField(draft.isGroup ? "分组名称" : "显示名称", text: $draft.name)
                if draft.isGroup {
                    Text("例如 gh 代码仓库。配置 gh 后接管内置 GitHub 搜索。")
                        .font(.caption).foregroundStyle(Theme.secondary)
                } else {
                    TextField("网址", text: $draft.url, prompt: Text("https://git.company.example/team/project-a"))
                    Text("支持 HTTP/HTTPS 内网域名、IP 和端口。")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    LabeledContent("别名") {
                        TextEditor(text: $draft.aliases).font(.system(size: 12)).frame(height: 66)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.controlBorder))
                    }
                    Text("可选，每行一个。例如：订单服务、后端仓库。")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("保存", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520).background(Theme.footerBase)
        .onAppear { if initial == nil { initial = draft } }
        .interactiveDismissDisabled()
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }
    private func cancel() { if dirty { confirmDiscard = true } else { dismiss() } }
    private func commit() {
        var config = configuration
        if draft.isGroup {
            if let index = draft.groupIndex {
                config.groups[index].keyword = draft.keyword; config.groups[index].name = draft.name
            } else { config.groups.append(.init(keyword: draft.keyword, name: draft.name)) }
        } else if let index = draft.groupIndex {
            let aliases = draft.aliases.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let item = WebsiteShortcut(key: draft.keyword, name: draft.name, url: draft.url, aliases: aliases)
            if let offset = draft.itemIndex { config.groups[index].items[offset] = item }
            else { config.groups[index].items.append(item) }
        }
        do { try save(config); dismiss() } catch { self.error = error.localizedDescription }
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
            Text("保存将替换全部网址配置。当前：\(current.groups.count) 个分组、\(current.itemCount) 个网址。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            ToolTextEditor(text: $text, json: true, label: "网址 JSON 配置")
                .padding(8).background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.controlBorder))
                .accessibilityLabel("网址 JSON 配置")
                .onChange(of: text) { _, _ in validate() }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3) }
            else if let validated {
                Text("校验通过：\(validated.groups.count) 个分组、\(validated.itemCount) 个网址")
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
