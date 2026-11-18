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

private struct ShortcutDeletion: Identifiable {
    let id = UUID()
    let group: Int
    let item: Int?
    let title: String
}
