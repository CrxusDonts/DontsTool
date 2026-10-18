import Foundation

/// 启动器面板的交互状态：结果分组、键盘选择、状态栏与 Toast。
/// 视图只读取这里的发布状态，窗口行为仍由 AppKit 壳层负责。
@MainActor
public final class LauncherPanelModel: ObservableObject {
    public struct Section: Identifiable {
        public let group: ResultGroup
        public let startIndex: Int
        public let items: [SearchItem]

        public var id: ResultGroup { group }
    }

    @Published public private(set) var items: [SearchItem] = []
    @Published public private(set) var status: SearchCoordinator.Status = .idle
    @Published public private(set) var selectedIndex = 0
    @Published public private(set) var progressMessage: String?
    @Published public private(set) var toastMessage: String?
    /// 搜索框当前的关键词前缀（json、tr 等），用于头部胶囊。
    @Published public private(set) var queryBadge: String?
    /// 空查询的默认列表：应用分组标题显示为“常用”。
    @Published public private(set) var isDefaultList = true
    /// 当前输入文本，用于头部清除按钮的显隐。
    @Published public private(set) var queryText = ""
    /// 头部显示的实际呼出快捷键。
    @Published public private(set) var hotKeyDisplay: String

    private let coordinator: SearchCoordinator
    private var toastTask: Task<Void, Never>?
    private var searchInterval: Performance.Interval?
    private var submittedQuery: String?

    public init(
        coordinator: SearchCoordinator,
        hotKeyDisplay: String,
        toastHold: Duration = .seconds(1.6)
    ) {
        self.coordinator = coordinator
        self.hotKeyDisplay = hotKeyDisplay
        self.toastHold = toastHold
        coordinator.onUpdate = { [weak self] update in
            self?.apply(update)
        }
    }

    private let toastHold: Duration

    public var sections: [Section] {
        var result: [Section] = []
        var index = 0
        for group in ResultGroup.allCases {
            let groupItems = items.filter { $0.group == group }
            guard !groupItems.isEmpty else { continue }
            result.append(Section(group: group, startIndex: index, items: groupItems))
            index += groupItems.count
        }
        return result
    }

    public var selectedItem: SearchItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    public var showsEmptyState: Bool {
        items.isEmpty && status != .searchingFiles
    }

    /// 底栏状态文本：进行中的进度优先，其次是搜索状态提示。
    public var statusText: String? {
        if let progressMessage { return progressMessage }
        switch status {
        case .idle:
            return nil
        case .searchingFiles:
            return "正在搜索文件…"
        case .message(let message):
            return message
        }
    }

    public var statusIsWarning: Bool {
        progressMessage == nil && status != .idle && status != .searchingFiles
    }

    public func item(at index: Int) -> SearchItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    public func submit(_ query: String, frontmostBundleID: String? = nil) {
        if submittedQuery != query {
            selectedIndex = 0
            submittedQuery = query
        }
        isDefaultList = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let searchInterval {
            Performance.end(searchInterval)
        }
        searchInterval = Performance.begin("search.fast")
        coordinator.submit(query, frontmostBundleID: frontmostBundleID)
    }

    public func updateQueryText(_ text: String) {
        guard queryText != text else { return }
        queryText = text
    }

    public func updateBadge(_ badge: String?) {
        guard queryBadge != badge else { return }
        queryBadge = badge
    }

    public func updateHotKeyDisplay(_ display: String) {
        guard hotKeyDisplay != display else { return }
        hotKeyDisplay = display
    }

    public func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), items.count - 1)
        guard next != selectedIndex else { return }
        selectedIndex = next
    }

    public func select(index: Int) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
    }

    public func beginProgress(_ message: String) {
        progressMessage = message
    }

    public func endProgress() {
        progressMessage = nil
    }

    public func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.toastHold)
            guard !Task.isCancelled else { return }
            self.toastMessage = nil
        }
    }

    private func apply(_ update: SearchCoordinator.Update) {
        if let searchInterval {
            Performance.end(searchInterval)
            self.searchInterval = nil
        }
        items = update.items
        status = update.status
        if !items.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
    }
}
