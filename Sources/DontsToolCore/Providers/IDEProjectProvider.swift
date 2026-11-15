import Foundation

@MainActor
public final class IDEProjectProvider: ToolProvider {
    public let id = "ideaProjects"
    public let displayName = "IDEA 项目"
    public let keywords = ["idea"]
    public let priority = 200
    public let phase = SearchPhase.fast
    public let supportsGlobalSearch = false
    public private(set) var statusNotice: String?

    private let index: AppIndex
    private let settings: SettingsStore
    private let usage: UsageStore
    private let launcher: any IDEProjectOpening
    private let feedback: any FeedbackProviding
    private let clipboard: any ClipboardProviding
    private let discovery: any IDEProjectDiscovering

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(index: AppIndex, settings: SettingsStore, usage: UsageStore, launcher: any IDEProjectOpening = SystemIDEProjectLauncher(), feedback: any FeedbackProviding, clipboard: any ClipboardProviding = SystemClipboard(), discovery: any IDEProjectDiscovering = IDEProjectDiscovery()) {
        self.index = index; self.settings = settings; self.usage = usage
        self.launcher = launcher; self.feedback = feedback; self.clipboard = clipboard; self.discovery = discovery
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        statusNotice = nil
        guard isEnabled, case .keyword(let providerID, let keyword, _) = context.mode, providerID == id, keyword == "idea" else { return [] }
        let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let manual = query.hasPrefix("/") || query.hasPrefix("~") || query.contains("://")
        let applications = index.apps.filter { $0.bundleID == "com.jetbrains.intellij" || $0.bundleID == "com.jetbrains.intellij.ce" }.map {
            IDEApplicationCandidate(url: $0.url, bundleID: $0.bundleID, name: $0.displayName)
        }
        let result = await discovery.discover(applications: applications, manualPath: manual ? query : nil)
        guard !Task.isCancelled, isEnabled else { return [] }
        statusNotice = result.notice
        guard let app = result.application else { return [hint(result.notice ?? "未找到 IntelliJ IDEA")] }
        let scored = result.projects.enumerated().compactMap { offset, project -> (IDERecentProject, Double)? in
            if query.isEmpty || manual { return (project, 1500 - Double(offset)) }
            guard let best = [project.name, project.url.lastPathComponent, project.url.path].compactMap({ FuzzyMatcher.score(query: query, candidate: $0) }).max() else { return nil }
            let exact = project.name.compare(query, options: .caseInsensitive) == .orderedSame || project.url.lastPathComponent.compare(query, options: .caseInsensitive) == .orderedSame
            return (project, exact ? 3000 : min(best, 2500))
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.lastOpenedTimestamp != $1.0.lastOpenedTimestamp { return $0.0.lastOpenedTimestamp > $1.0.lastOpenedTimestamp }
            return $0.0.url.path < $1.0.url.path
        }
        guard !scored.isEmpty else {
            return [hint(result.notice ?? (query.isEmpty ? "暂无可打开的最近项目；可输入完整项目目录" : "没有匹配的项目；可输入完整项目目录"))]
        }
        return scored.prefix(30).map { item($0.0, application: app, score: $0.1) }
    }

    private func item(_ project: IDERecentProject, application: IDEApplication, score: Double) -> SearchItem {
        let launcher = self.launcher; let discovery = self.discovery
        let feedback = self.feedback; let clipboard = self.clipboard; let usage = self.usage
        let settings = self.settings; let providerID = id
        let key = "idea-project:\(project.url.path)"
        return SearchItem(providerID: id, group: .tool, title: project.name, subtitle: "\(project.url.path) · \(application.name) \(application.version)", icon: .application(path: application.url.path), score: score, canonicalKey: key, actions: [
            ItemAction(id: "idea.project.open", title: "用 IDEA 打开", symbol: "arrow.up.forward.app") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                let isLocalDirectory = await discovery.isLocalDirectory(project.url)
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                guard isLocalDirectory else { feedback.show("项目目录不存在或不是本地目录"); return }
                do {
                    try await launcher.openProject(at: project.url, using: application.url)
                    usage.recordUse(of: key)
                } catch { feedback.show("无法用 IDEA 打开项目：\(error.localizedDescription)") }
            },
            ItemAction(id: "idea.project.reveal", title: "在访达中显示", symbol: "folder") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                launcher.revealInFinder(project.url)
            },
            ItemAction(id: "idea.project.copyPath", title: "复制路径", symbol: "doc.on.doc") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                clipboard.writeString(project.url.path)
                feedback.show("已复制路径")
            }
        ])
    }

    private func hint(_ message: String) -> SearchItem {
        let feedback = self.feedback
        return SearchItem(providerID: id, group: .tool, title: "IDEA 项目", subtitle: message, icon: .symbol(name: "folder", tint: .purple), score: 1000, canonicalKey: "idea-project:hint", actions: [ItemAction(id: "idea.project.hint", title: "提示", presentation: .keepPanelOpen, symbol: "info.circle") { feedback.show(message) }], keyword: "idea")
    }
}
