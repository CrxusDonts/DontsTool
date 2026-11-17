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
    @Published public private(set) var isComposing = false
    @Published public private(set) var selectedIndex = 0
    @Published public private(set) var progressMessage: String?
    @Published public private(set) var toastMessage: String?
    @Published public private(set) var queryRoute: KeywordRoute?
    public var queryBadge: String? { queryRoute?.keyword }
    /// 空查询的默认列表：应用分组标题显示为“常用”。
    @Published public private(set) var isDefaultList = true
    /// 当前输入文本，用于头部清除按钮的显隐。
    @Published public private(set) var queryText = ""
    /// 头部显示的实际呼出快捷键。
    @Published public private(set) var hotKeyDisplay: String
    /// 当前结果的动作面板是否展开（⌘K）。
    @Published public private(set) var isActionPanelOpen = false
    @Published public private(set) var selectedActionIndex = 0
    @Published public private(set) var attachedContent: ContentDescriptor?

    private let coordinator: SearchCoordinator
    private var toastTask: Task<Void, Never>?
    private var searchInterval: Performance.Interval?
    private var submittedQuery: String?
    private let contentProvider: ContentActionProvider?
    private var contentText: String?

    public init(
        coordinator: SearchCoordinator,
        hotKeyDisplay: String,
        toastHold: Duration = .seconds(1.6),
        contentProvider: ContentActionProvider? = nil
    ) {
        self.coordinator = coordinator
        self.hotKeyDisplay = hotKeyDisplay
        self.contentProvider = contentProvider
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

    public var actionItems: [ItemAction] {
        selectedItem?.actions ?? []
    }

    public var selectedAction: ItemAction? {
        actionItems.indices.contains(selectedActionIndex) ? actionItems[selectedActionIndex] : nil
    }

    public var showsEmptyState: Bool {
        !isComposing && items.isEmpty && status != .searchingFiles
    }

    /// 底栏状态文本：进行中的进度优先，其次是搜索状态提示。
    public var statusText: String? {
        if isComposing { return "输入完成后搜索" }
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
        !isComposing && progressMessage == nil && status != .idle && status != .searchingFiles
    }

    public func item(at index: Int) -> SearchItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    public func submit(_ query: String, frontmostBundleID: String? = nil) {
        isComposing = false
        if submittedQuery != query {
            selectedIndex = 0
            submittedQuery = query
            closeActionPanel()
        }
        isDefaultList = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let contentText, let contentProvider {
            coordinator.cancel()
            isDefaultList = false
            replaceResults(contentProvider.items(for: contentText, matching: query), status: .idle)
            return
        }
        if let searchInterval {
            Performance.end(searchInterval)
        }
        searchInterval = Performance.begin("search.fast")
        coordinator.submit(query, frontmostBundleID: frontmostBundleID)
    }

    public func suspendSearchForComposition() {
        coordinator.cancel()
        if let searchInterval { Performance.end(searchInterval); self.searchInterval = nil }
        isComposing = true
        closeActionPanel()
        replaceResults([], status: .idle)
    }

    @discardableResult
    public func attachContent(_ text: String) -> Bool {
        guard contentProvider != nil, let descriptor = ContentDescriptor(text: text) else { return false }
        coordinator.cancel()
        if let searchInterval { Performance.end(searchInterval); self.searchInterval = nil }
        closeActionPanel()
        attachedContent = descriptor
        contentText = text
        queryText = ""
        queryRoute = nil
        submittedQuery = nil
        selectedIndex = 0
        submit("")
        return true
    }

    @discardableResult
    public func clearContent() -> Bool {
        guard attachedContent != nil else { return false }
        attachedContent = nil
        contentText = nil
        queryText = ""
        queryRoute = nil
        submittedQuery = nil
        closeActionPanel()
        // Drop closures retaining the source before starting asynchronous search.
        replaceResults([], status: .idle)
        selectedIndex = 0
        submit("")
        return true
    }

    public func updateQueryText(_ text: String) {
        guard queryText != text else { return }
        queryText = text
    }

    public func updateQueryRoute(_ route: KeywordRoute?) {
        guard queryRoute != route else { return }
        queryRoute = route
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
        if isActionPanelOpen {
            selectedActionIndex = 0
        }
    }

    public func toggleActionPanel() {
        if isActionPanelOpen {
            closeActionPanel()
        } else {
            openActionPanel()
        }
    }

    public func openActionPanel() {
        guard !actionItems.isEmpty else { return }
        selectedActionIndex = 0
        isActionPanelOpen = true
    }

    public func closeActionPanel() {
        guard isActionPanelOpen || selectedActionIndex != 0 else { return }
        isActionPanelOpen = false
        selectedActionIndex = 0
    }

    public func moveActionSelection(by delta: Int) {
        guard isActionPanelOpen, !actionItems.isEmpty else { return }
        selectedActionIndex = min(max(selectedActionIndex + delta, 0), actionItems.count - 1)
    }

    public func selectAction(index: Int) {
        guard isActionPanelOpen, actionItems.indices.contains(index) else { return }
        selectedActionIndex = index
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
        guard attachedContent == nil else { return }
        if let searchInterval {
            Performance.end(searchInterval)
            self.searchInterval = nil
        }
        replaceResults(update.items, status: update.status)
    }

    private func replaceResults(_ items: [SearchItem], status: SearchCoordinator.Status) {
        self.items = items
        self.status = status
        if !items.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
        if isActionPanelOpen {
            if actionItems.isEmpty {
                closeActionPanel()
            } else {
                selectedActionIndex = min(selectedActionIndex, actionItems.count - 1)
            }
        }
    }
}
