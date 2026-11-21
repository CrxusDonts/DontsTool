import DontsToolCore
import SwiftUI

struct ToolsSettingsTabView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(caption: "内置工具") {
                ForEach(Array(providerEntries.enumerated()), id: \.offset) { offset, entry in
                    if offset > 0 { SettingsDivider() }
                    SettingsRow(title: entry.name, subtitle: entry.hint) {
                        Toggle("", isOn: Binding(
                            get: { settings.isProviderEnabled(entry.id) },
                            set: { settings.setProviderEnabled(entry.id, to: $0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
        }
    }

    private var providerEntries: [(id: String, name: String, hint: String)] {
        [
            (ProviderID.app.rawValue, "应用启动", "搜索并打开本机应用"),
            (ProviderID.text.rawValue, "文本工具", "json、base64、url、时间戳、哈希、UUID"),
            (ProviderID.web.rawValue, "网页搜索", "关键词或默认引擎回退"),
            (ProviderID.translation.rawValue, "翻译", "tr 关键词调用模型服务翻译"),
            (ProviderID.notes.rawValue, "本地便笺", "note · 所见即所得、Markdown 和图片"),
            (ProviderID.calculator.rawValue, "计算器", "算式与单位换算，回车复制结果"),
            (ProviderID.quickOpen.rawValue, "快速打开", "直接打开网址或已存在的绝对路径")
        ]
    }
}
