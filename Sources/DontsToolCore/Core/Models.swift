import Foundation

public enum ProviderID: String, CaseIterable, Identifiable, Sendable {
    case app
    case file
    case text
    case web
    case translation
    case knowledge
    case calculator
    case quickOpen = "quickOpen"
    case gemini
    case ideaProjects

    public var id: String { rawValue }
}

public enum SearchMode: Equatable, Sendable {
    case global
    case keyword(providerID: String, keyword: String, argument: String)
}

public struct SearchContext: Equatable, Sendable {
    public let rawQuery: String
    public let mode: SearchMode
    public let frontmostBundleID: String?

    public init(rawQuery: String, mode: SearchMode, frontmostBundleID: String? = nil) {
        self.rawQuery = rawQuery
        self.mode = mode
        self.frontmostBundleID = frontmostBundleID
    }

    public var query: String {
        switch mode {
        case .global:
            rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        case .keyword(_, _, let argument):
            argument
        }
    }
}

public struct KeywordRoute: Equatable, Sendable {
    public let providerID: String
    public let keyword: String

    public init(providerID: String, keyword: String) {
        self.providerID = providerID
        self.keyword = keyword
    }
}

public enum ResultGroup: Int, CaseIterable, Comparable, Sendable {
    case app = 0
    case tool = 1
    case knowledge = 2
    case file = 3
    case web = 4
    case shortcut = 5

    public static func < (lhs: ResultGroup, rhs: ResultGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum IconTint: String, CaseIterable, Sendable {
    case blue
    case sky
    case teal
    case green
    case amber
    case orange
    case red
    case purple
    case indigo
    case gray
}

public enum ItemIcon: Equatable, Sendable {
    case application(path: String)
    case file(path: String)
    case symbol(name: String, tint: IconTint)
    case glyph(text: String, tint: IconTint)
}

public enum ActionPresentation: Sendable {
    case openWindow
    case dismissThenRun
    case keepPanelUntilComplete
    case keepPanelOpen
}

public enum FileActionKind: Sendable {
    case reveal
    case copyPath
}

public struct ItemAction {
    public let id: String
    public let title: String
    public let presentation: ActionPresentation
    public let symbol: String?
    public let fileAction: FileActionKind?
    public let run: @MainActor () async throws -> Void

    public init(
        id: String,
        title: String,
        presentation: ActionPresentation = .dismissThenRun,
        symbol: String? = nil,
        fileAction: FileActionKind? = nil,
        run: @escaping @MainActor () async throws -> Void
    ) {
        self.id = id
        self.title = title
        self.presentation = presentation
        self.symbol = symbol
        self.fileAction = fileAction
        self.run = run
    }
}

public struct SearchItemBadge: Equatable, Sendable {
    public let text: String
    public let tint: IconTint

    public init(text: String, tint: IconTint) {
        self.text = text
        self.tint = tint
    }
}

public struct SearchItem: Identifiable {
    public let id: String
    public let providerID: String
    public let group: ResultGroup
    public let title: String
    public let subtitle: String?
    public let icon: ItemIcon
    public let score: Double
    public let canonicalKey: String
    public let actions: [ItemAction]
    /// 行尾展示的关键词标签（json、tr 等），仅提示类结果使用。
    public let keyword: String?
    public let badge: SearchItemBadge?

    public init(
        id: String? = nil,
        providerID: String,
        group: ResultGroup,
        title: String,
        subtitle: String? = nil,
        icon: ItemIcon,
        score: Double,
        canonicalKey: String,
        actions: [ItemAction],
        keyword: String? = nil,
        badge: SearchItemBadge? = nil
    ) {
        self.id = id ?? "\(providerID):\(canonicalKey)"
        self.providerID = providerID
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.score = score
        self.canonicalKey = canonicalKey
        self.actions = actions
        self.keyword = keyword
        self.badge = badge
    }

    public var primaryAction: ItemAction? { actions.first }
    public var secondaryAction: ItemAction? { actions.dropFirst().first }

    public func fileAction(_ kind: FileActionKind) -> ItemAction? {
        guard case .file = icon else { return nil }
        return actions.first { $0.fileAction == kind }
    }
}

public enum SearchPhase: Sendable {
    case fast
    case slow
}

@MainActor
public protocol ToolProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var keywords: [String] { get }
    var priority: Int { get }
    var isEnabled: Bool { get set }
    var phase: SearchPhase { get }
    var supportsGlobalSearch: Bool { get }
    var statusNotice: String? { get }

    func search(_ context: SearchContext) async -> [SearchItem]
}

extension ToolProvider {
    public var phase: SearchPhase { .fast }
    public var supportsGlobalSearch: Bool { true }
    public var statusNotice: String? { nil }
}
