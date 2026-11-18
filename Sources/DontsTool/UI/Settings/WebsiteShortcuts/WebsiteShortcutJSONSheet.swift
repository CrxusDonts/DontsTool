import DontsToolCore
import SwiftUI

struct ShortcutJSONSheet: View {
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
