import Foundation

public enum ToolKind: String, CaseIterable, Identifiable, Sendable {
    case json, base64, url, timestamp, uuid, hash, translation
    public var id: String { rawValue }
    public var launcherKey: String { "tool:\(rawValue)" }
    public var title: String {
        switch self {
        case .json: "JSON 工具"
        case .base64: "Base64 编解码"
        case .url: "URL 编解码"
        case .timestamp: "时间戳转换"
        case .uuid: "UUID 生成器"
        case .hash: "哈希计算"
        case .translation: "翻译"
        }
    }
    public var keywords: [String] {
        switch self {
        case .json: ["json"]
        case .base64: ["b64", "b64d", "base64"]
        case .url: ["url", "urld"]
        case .timestamp: ["ts", "timestamp"]
        case .uuid: ["uuid"]
        case .hash: ["md5", "sha1", "sha256", "hash"]
        case .translation: ["tr", "translate"]
        }
    }
    public var summary: String {
        switch self {
        case .json: "格式化、压缩、转义与结构对比"
        case .base64: "UTF-8 文本编码与解码 · 支持 URL-safe"
        case .url: "URL 组件与表单编码、解码"
        case .timestamp: "日期与秒、毫秒时间戳互转"
        case .uuid: "批量生成 UUID v4 · 自定义显示格式"
        case .hash: "MD5、SHA1、SHA256 文本摘要"
        case .translation: "编辑原文、翻译、查看与复制译文"
        }
    }
    public var defaultMode: String {
        switch self { case .json: "format"; case .base64, .url: "encode"; case .hash: "sha256"; default: rawValue }
    }
    public var icon: ItemIcon {
        switch self {
        case .json: .glyph(text: "{}", tint: .amber)
        case .base64: .glyph(text: "64", tint: .purple)
        case .url: .symbol(name: "link", tint: .teal)
        case .timestamp: .symbol(name: "clock", tint: .indigo)
        case .uuid: .symbol(name: "tag", tint: .indigo)
        case .hash: .symbol(name: "number.square", tint: .gray)
        case .translation: .symbol(name: "character.bubble", tint: .teal)
        }
    }
    public static func forKeyword(_ keyword: String) -> ToolKind? { allCases.first { $0.keywords.contains(keyword) } }
    @MainActor public func entry(providerID: String, keyword: String? = nil, input: String? = nil, opener: any ToolOpening) -> SearchItem {
        let mode = ["b64d", "urld"].contains(keyword ?? "") ? "decode" : ["md5", "sha1", "sha256"].contains(keyword ?? "") ? keyword! : defaultMode
        return SearchItem(providerID: providerID, group: .tool, title: title, subtitle: summary,
            icon: icon, score: 1000 - Double(Self.allCases.firstIndex(of: self) ?? 0), canonicalKey: launcherKey,
            actions: [ItemAction(id: "tool.open.\(rawValue)", title: "新建窗口", presentation: .openWindow) {
                opener.openTool(ToolOpenRequest(kind: self, mode: mode, input: input))
            }], keyword: keywords.first)
    }
    public func matches(_ query: String) -> Bool {
        let query = query.lowercased()
        return title.lowercased().contains(query) || rawValue.contains(query) || keywords.contains(where: { $0.contains(query) }) || summary.lowercased().contains(query)
    }
}
public struct ToolOpenRequest: Sendable, Equatable {
    public let kind: ToolKind
    public let mode: String?
    public let input: String?
    public init(kind: ToolKind, mode: String? = nil, input: String? = nil) { self.kind = kind; self.mode = mode; self.input = input }
}
@MainActor public protocol ToolOpening: AnyObject { func openTool(_ request: ToolOpenRequest) }
