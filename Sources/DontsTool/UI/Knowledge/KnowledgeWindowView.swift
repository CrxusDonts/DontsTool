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
                Text("正在等待其他窗口确认退出…")
                    .font(.callout)
                    .foregroundStyle(ToolTheme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .contentShape(Rectangle())
            }
            switch bridge.state {
            case .ready:
                EmptyView()
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().tint(ToolTheme.accent)
                    Text("正在连接知识库…").font(.system(size: 12.5)).foregroundStyle(ToolTheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToolTheme.workspace)
            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(ToolTheme.secondary)
                    Text("知识库暂时无法使用").font(.system(size: 16, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ToolTheme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    HStack(spacing: 10) {
                        Button("重新连接", action: onReload).buttonStyle(.borderedProminent)
                        Button("服务地址设置", action: onSettings)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToolTheme.workspace)
            }
        }
        .foregroundStyle(ToolTheme.ink)
        .background(ToolTheme.workspace)
        .tint(ToolTheme.accent)
    }
}

private struct KnowledgeWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
