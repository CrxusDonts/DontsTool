import DontsToolCore
import SwiftUI
import WebKit

struct KnowledgeWindowView: View {
    @ObservedObject var bridge: KnowledgeWebBridge
    let onReload: () -> Void
    let onSettings: () -> Void
    let locked: Bool
    var body: some View {
        ZStack {
            KnowledgeWebView(webView: bridge.webView)
            if locked {
                Text("正在等待其他窗口确认退出…").font(.callout).foregroundStyle(ToolTheme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ToolTheme.workspace.opacity(0.92)).contentShape(Rectangle())
            }
            switch bridge.state {
            case .ready: EmptyView()
            case .loading:
                VStack(spacing: 14) { ProgressView(); Text("正在连接知识库…").foregroundStyle(ToolTheme.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(ToolTheme.workspace)
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "network.slash").font(.system(size: 28)).foregroundStyle(ToolTheme.secondary)
                    Text("知识库暂时无法使用").font(.title3.weight(.medium))
                    Text(message).foregroundStyle(ToolTheme.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                    HStack { Button("重新连接", action: onReload); Button("服务地址设置", action: onSettings) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ToolTheme.workspace)
            }
        }
        .foregroundStyle(ToolTheme.ink).background(ToolTheme.workspace)
    }
}
private struct KnowledgeWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
