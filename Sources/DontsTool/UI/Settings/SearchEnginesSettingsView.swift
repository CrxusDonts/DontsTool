import AppKit
import DontsToolCore
import SwiftUI

struct SearchEnginesSettingsView: View {
    @ObservedObject var store: SearchEngineStore
    @ObservedObject var websites: WebsiteShortcutStore
    @State private var editing: EngineDraft?
    @State private var jsonDraft: EngineJSONDraft?
    @State private var deletion: SearchEngineDefinition?
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("搜索引擎").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("JSON 配置") { jsonDraft = EngineJSONDraft(text: store.editableJSON) }
                Button("复制 JSON") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.editableJSON, forType: .string)
                    notice = "已复制搜索引擎配置"; error = nil
                }
                Button("添加引擎") { editing = EngineDraft() }
            }.controlSize(.small)
            Text("输入“快捷词 搜索内容”调用对应引擎，例如 g Swift 并发。也可以搜索引擎名称，再回车填入快捷词。")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            if let message = error ?? store.loadError {
                Text(message).font(.system(size: 12)).foregroundStyle(Color.red)
            } else if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(Theme.success)
            }
            SettingsGroup(caption: "默认引擎") {
                SettingsRow(title: "网页搜索回退", subtitle: "普通查询使用此引擎提供网页搜索结果") {
                    Picker("默认搜索引擎", selection: Binding(get: { store.configuration.defaultEngineID }, set: { id in
                        change { $0.defaultEngineID = id }
                    })) {
                        ForEach(store.configuration.enabledEngines) { engine in
                            Text(engine.name).tag(engine.id)
                        }
                    }.labelsHidden().frame(width: 145)
                }
            }
            SettingsGroup(caption: "已配置引擎") {
                ForEach(Array(store.configuration.engines.enumerated()), id: \.element.id) { index, engine in
                    if index > 0 { SettingsDivider() }
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("启用 \(engine.name)", isOn: Binding(get: { engine.isEnabled }, set: { enabled in
                            change { config in
                                guard let offset = config.engines.firstIndex(where: { $0.id == engine.id }) else { return }
                                config.engines[offset].isEnabled = enabled
                                if !enabled && config.defaultEngineID == engine.id,
                                   let next = config.enabledEngines.first { config.defaultEngineID = next.id }
                            }
                        })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(engine.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(engine.keyword).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                                if engine.id == store.configuration.defaultEngineID { SettingsBadge(text: "默认") }
                            }
                            Text(engine.urlTemplate).font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle).help(engine.urlTemplate)
                            if engine.isEnabled && websiteKeywords.contains(engine.keyword) {
                                Text("\(engine.keyword) 已由网址快捷入口接管；可修改搜索快捷词。")
                                    .font(.system(size: 11)).foregroundStyle(Color.red)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("编辑") { editing = EngineDraft(engine: engine) }.controlSize(.small)
                        Button { deletion = engine } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                            .help("删除 \(engine.name)").accessibilityLabel("删除 \(engine.name)")
                    }.padding(12)
                }
            }
        }
        .sheet(item: $editing) { draft in
            SearchEngineEditor(draft: draft, current: store.configuration, validate: validate) { proposal in
                try save(proposal); notice = "已保存，快捷词即时生效"
            }
        }
        .sheet(item: $jsonDraft) { draft in
            SearchEngineJSONEditor(original: draft.text, validate: validate) { proposal in
                try save(proposal); notice = "搜索引擎配置已更新"
            }
        }
        .alert(item: $deletion) { engine in
            Alert(title: Text("删除“\(engine.name)”？"), message: Text("删除后该搜索快捷词将不再可用。"),
                primaryButton: .destructive(Text("删除")) {
                    change { config in
                        config.engines.removeAll { $0.id == engine.id }
                        if config.defaultEngineID == engine.id, let next = config.enabledEngines.first {
                            config.defaultEngineID = next.id
                        }
                    }
                }, secondaryButton: .cancel(Text("取消")))
        }
    }

    private var websiteKeywords: Set<String> { Set(websites.configuration.groups.map(\.keyword)) }

    private func validate(_ proposed: SearchEngineConfiguration) throws -> SearchEngineConfiguration {
        try proposed.validated(reservedKeywords: SearchEngineKeywordRules.reservedKeywords(
            current: store.configuration, proposed: proposed, websiteKeywords: websiteKeywords))
    }

    private func save(_ proposed: SearchEngineConfiguration) throws {
        let keywords = SearchEngineKeywordRules.reservedKeywords(current: store.configuration,
            proposed: proposed, websiteKeywords: websiteKeywords)
        try store.save(proposed, reservedKeywords: keywords)
        error = nil
    }

    private func change(_ mutate: (inout SearchEngineConfiguration) -> Void) {
        var proposal = store.configuration
        mutate(&proposal)
        do { try save(proposal); notice = "已保存，启动器中即时生效" }
        catch { self.error = error.localizedDescription }
    }
}

struct EngineDraft: Identifiable {
    var id: String
    var name: String
    var keyword: String
    var urlTemplate: String
    var isEnabled: Bool
    let original: SearchEngineDefinition?

    init(engine: SearchEngineDefinition? = nil) {
        id = engine?.id ?? UUID().uuidString
        name = engine?.name ?? ""
        keyword = engine?.keyword ?? ""
        urlTemplate = engine?.urlTemplate ?? ""
        isEnabled = engine?.isEnabled ?? true
        original = engine
    }

    var engine: SearchEngineDefinition {
        SearchEngineDefinition(id: id, name: name, keyword: keyword, urlTemplate: urlTemplate, isEnabled: isEnabled)
    }
    var isDirty: Bool { original.map { engine != $0 } ?? (!name.isEmpty || !keyword.isEmpty || !urlTemplate.isEmpty || !isEnabled) }

    func applying(to current: SearchEngineConfiguration) -> SearchEngineConfiguration {
        var config = current
        if let index = config.engines.firstIndex(where: { $0.id == id }) { config.engines[index] = engine }
        else { config.engines.append(engine) }
        if config.defaultEngineID == id && !isEnabled, let next = config.enabledEngines.first {
            config.defaultEngineID = next.id
        }
        return config
    }
}

private struct EngineJSONDraft: Identifiable { let id = UUID(); let text: String }

struct SearchEngineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: EngineDraft
    let current: SearchEngineConfiguration
    let validate: (SearchEngineConfiguration) throws -> SearchEngineConfiguration
    let save: (SearchEngineConfiguration) throws -> Void
    @State private var previewQuery = "Swift 并发 + 中文"
    @State private var error: String?
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "添加搜索引擎" : "编辑搜索引擎").font(.system(size: 17, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                field("名称", text: $draft.name, placeholder: "公司文档")
                field("快捷词", text: $draft.keyword, placeholder: "wiki")
                field("网址模板", text: $draft.urlTemplate, placeholder: "https://docs.example.com/search?q={query}")
            }
            Text("用 {query} 标记关键词的位置。支持路径、查询参数和页面片段；中文与特殊符号会自动编码。")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Toggle("启用此引擎", isOn: $draft.isEnabled).font(.system(size: 12))
            Divider()
            TextField("预览搜索内容", text: $previewQuery).textFieldStyle(.roundedBorder).font(.system(size: 12))
                .accessibilityLabel("预览搜索内容")
            Text(draft.engine.searchURL(for: previewQuery)?.absoluteString ?? "填写有效的网址模板后显示预览")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                .textSelection(.enabled).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.red).lineLimit(3) }
            HStack {
                Spacer()
                Button("取消") { if draft.isDirty { confirmDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { let proposal = try validate(draft.applying(to: current)); try save(proposal); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 600).background(Theme.footerBase)
            .interactiveDismissDisabled()
            .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        GridRow {
            Text(title).font(.system(size: 12)).frame(width: 60, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
                .accessibilityLabel(title)
        }
    }
}

private struct SearchEngineJSONEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: String
    let validate: (SearchEngineConfiguration) throws -> SearchEngineConfiguration
    let save: (SearchEngineConfiguration) throws -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var valid: SearchEngineConfiguration?
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("搜索引擎 JSON 配置").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("格式化") {
                    do { text = try SearchEngineConfiguration.decode(text).json(); check() }
                    catch { self.error = error.localizedDescription }
                }.controlSize(.small)
            }
            Text("保存将替换全部搜索引擎。defaultEngineID 指定默认引擎，urlTemplate 中用 {query} 放置关键词。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            ToolTextEditor(text: $text, json: true, label: "搜索引擎 JSON 配置")
                .padding(8).background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.controlBorder))
                .onChange(of: text) { _, _ in check() }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.red).lineLimit(3) }
            else if let valid {
                Text("校验通过 · \(valid.enabledEngines.count) 个启用引擎 · 默认：\(valid.defaultEngine.name)")
                    .font(.system(size: 12)).foregroundStyle(Theme.success)
            }
            HStack {
                Spacer()
                Button("取消") { if text != original { confirmDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("保存配置") {
                    do { try save(validate(SearchEngineConfiguration.decode(text))); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(valid == nil)
            }
        }.padding(20).frame(width: 660, height: 520).background(Theme.footerBase)
            .onAppear { text = original; check() }.interactiveDismissDisabled()
            .confirmationDialog("放弃未保存的 JSON 修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
    }

    private func check() {
        do { valid = try validate(SearchEngineConfiguration.decode(text)); error = nil }
        catch { valid = nil; self.error = error.localizedDescription }
    }
}
