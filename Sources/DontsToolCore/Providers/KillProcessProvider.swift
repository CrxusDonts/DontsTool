import Foundation

@MainActor
public final class KillProcessProvider: ToolProvider {
    public let id = ProviderID.killProcess.rawValue
    public let displayName = "结束进程"
    public let priority = 200
    public let phase = SearchPhase.fast
    public private(set) var statusNotice: String?
    public var onProcessesChanged: (@MainActor () -> Void)?

    public var keywords: [String] {
        let unavailable = Set(unavailableKeywords().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return ["kill", "kp", "进程"].filter { !unavailable.contains($0) }
    }

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    private let settings: SettingsStore
    private let service: any ProcessControlling
    private let prefill: (any QueryPrefilling)?
    private let clipboard: (any ClipboardProviding)?
    private let feedback: (any FeedbackProviding)?
    private let revealInFinder: (@MainActor (URL) -> Void)?
    private let unavailableKeywords: @MainActor () -> Set<String>
    private let cacheTTL: TimeInterval
    private let nowProvider: @Sendable () -> Date

    private var cachedProcesses: [RunningProcess] = []
    private var cacheTimestamp: Date = .distantPast

    public init(
        settings: SettingsStore,
        service: any ProcessControlling = SystemProcessService(),
        prefill: (any QueryPrefilling)? = nil,
        clipboard: (any ClipboardProviding)? = nil,
        feedback: (any FeedbackProviding)? = nil,
        revealInFinder: (@MainActor (URL) -> Void)? = nil,
        unavailableKeywords: @escaping @MainActor () -> Set<String> = { [] },
        cacheTTL: TimeInterval = 1.5,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.service = service
        self.prefill = prefill
        self.clipboard = clipboard
        self.feedback = feedback
        self.revealInFinder = revealInFinder
        self.unavailableKeywords = unavailableKeywords
        self.cacheTTL = cacheTTL
        self.nowProvider = nowProvider
    }

    public func invalidateCache() {
        cacheTimestamp = .distantPast
        cachedProcesses = []
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        statusNotice = nil
        guard isEnabled, !Task.isCancelled else { return [] }

        switch context.mode {
        case .global:
            let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return [] }
            let aliases = ["kill", "kill process", "kp", "结束进程", "杀进程", "进程"]
            guard aliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) else {
                return []
            }
            return [discoveryEntry()]

        case .keyword(let providerID, let keyword, _) where providerID == id:
            guard keywords.contains(keyword.lowercased()) else { return [] }
            let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)

            if let port = parsePortQuery(query) {
                return await searchByPort(port)
            }

            let processes: [RunningProcess]
            do {
                processes = try await loadProcesses()
            } catch {
                guard !Task.isCancelled else { return [] }
                statusNotice = error.localizedDescription
                return [hintItem(title: "无法读取进程列表", subtitle: error.localizedDescription)]
            }
            guard !Task.isCancelled, isEnabled else { return [] }

            let nameCounts = Dictionary(grouping: processes, by: { $0.name.lowercased() }).mapValues(\.count)
            let ranked = rank(processes: processes, query: query)
            guard !ranked.isEmpty else {
                return [hintItem(
                    title: query.isEmpty ? "没有可结束的用户进程" : "没有匹配的进程",
                    subtitle: query.isEmpty ? "当前没有符合条件的运行中进程" : "可按进程名、PID、启动命令或 :端口号 筛选"
                )]
            }
            return ranked.prefix(30).map { entry in
                makeProcessItem(
                    entry.process,
                    score: entry.score,
                    matchingNameCount: nameCounts[entry.process.name.lowercased(), default: 1],
                    portBadge: nil
                )
            }

        default:
            return []
        }
    }

    private func searchByPort(_ port: UInt16) async -> [SearchItem] {
        let pids: Set<Int32>
        let processes: [RunningProcess]
        do {
            pids = try await service.listeningPIDs(onPort: port)
            processes = try await loadProcesses(forceRefresh: true)
        } catch {
            guard !Task.isCancelled else { return [] }
            statusNotice = error.localizedDescription
            return [hintItem(title: "端口查询失败", subtitle: error.localizedDescription)]
        }
        guard !Task.isCancelled, isEnabled else { return [] }

        let matching = processes
            .filter { pids.contains($0.pid) }
            .sorted { $0.memoryBytes > $1.memoryBytes }

        guard !matching.isEmpty else {
            return [hintItem(
                title: "端口 :\(port) 无监听进程",
                subtitle: "当前用户下没有监听 TCP 端口 \(port) 的进程"
            )]
        }

        let nameCounts = Dictionary(grouping: processes, by: { $0.name.lowercased() }).mapValues(\.count)
        return matching.enumerated().map { index, process in
            makeProcessItem(
                process,
                score: 3000 - Double(index),
                matchingNameCount: nameCounts[process.name.lowercased(), default: 1],
                portBadge: ":\(port)"
            )
        }
    }

    private func loadProcesses(forceRefresh: Bool = false) async throws -> [RunningProcess] {
        let now = nowProvider()
        if !forceRefresh, !cachedProcesses.isEmpty, now.timeIntervalSince(cacheTimestamp) < cacheTTL {
            return cachedProcesses
        }
        let fresh = try await service.listProcesses()
        guard !Task.isCancelled else { return [] }
        cachedProcesses = fresh
        cacheTimestamp = nowProvider()
        return fresh
    }

    private func rank(processes: [RunningProcess], query: String) -> [(process: RunningProcess, score: Double)] {
        if query.isEmpty {
            return processes
                .sorted { lhs, rhs in
                    let lhsHot = lhs.cpuPercent >= 25
                    let rhsHot = rhs.cpuPercent >= 25
                    if lhsHot != rhsHot { return lhsHot }
                    if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
                    if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
                    return lhs.pid < rhs.pid
                }
                .enumerated()
                .map { offset, process in (process, 2000 - Double(offset)) }
        }

        let lowerQuery = query.lowercased()
        let pidQuery = Int32(query)

        var scored: [(process: RunningProcess, score: Double)] = []
        for process in processes {
            let pidString = String(process.pid)
            let score: Double?
            if let pidQuery, process.pid == pidQuery {
                score = 3500
            } else if process.name.compare(query, options: .caseInsensitive) == .orderedSame {
                score = 3000
            } else if let nameScore = FuzzyMatcher.score(query: query, candidate: process.name) {
                score = 2000 + min(nameScore, 900)
            } else if pidString.hasPrefix(query) {
                score = 1800
            } else if process.commandLine.lowercased().contains(lowerQuery) {
                score = 1500
            } else if process.executablePath.lowercased().contains(lowerQuery) {
                score = 1400
            } else {
                score = nil
            }
            if let score {
                scored.append((process, score))
            }
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.process.memoryBytes != rhs.process.memoryBytes { return lhs.process.memoryBytes > rhs.process.memoryBytes }
            if lhs.process.cpuPercent != rhs.process.cpuPercent { return lhs.process.cpuPercent > rhs.process.cpuPercent }
            return lhs.process.pid < rhs.process.pid
        }
    }

    private func makeProcessItem(
        _ process: RunningProcess,
        score: Double,
        matchingNameCount: Int,
        portBadge: String?
    ) -> SearchItem {
        let icon: ItemIcon
        if let appPath = process.appBundlePath {
            icon = .application(path: appPath)
        } else {
            icon = .symbol(name: "terminal", tint: .gray)
        }

        let badgeText = portBadge.map { "\($0) · \(process.formattedMemory)" } ?? process.formattedMemory
        let badgeTint: IconTint
        if portBadge != nil {
            badgeTint = .blue
        } else if process.memoryBytes >= 1_073_741_824 || process.cpuPercent >= 80 {
            badgeTint = .red
        } else if process.memoryBytes >= 314_572_800 || process.cpuPercent >= 30 {
            badgeTint = .amber
        } else {
            badgeTint = .gray
        }

        let summaryPath = process.commandLine.count > 96
            ? String(process.commandLine.prefix(96)) + "…"
            : process.commandLine
        let subtitle = "PID \(process.pid) · CPU \(process.formattedCPU) · \(summaryPath)"

        let providerID = id
        let settings = self.settings
        let service = self.service
        let feedback = self.feedback
        let clipboard = self.clipboard
        let revealInFinder = self.revealInFinder

        var actions: [ItemAction] = [
            ItemAction(id: "process.terminate", title: "结束进程", presentation: .keepPanelOpen, symbol: "xmark.circle") { [weak self] in
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    try await service.terminate(pid: process.pid, signal: .terminate)
                    self?.invalidateCache()
                    feedback?.show("已结束 \(process.name)（PID \(process.pid)）")
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.onProcessesChanged?()
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            },
            ItemAction(id: "process.forceKill", title: "强制结束 (SIGKILL)", presentation: .keepPanelOpen, symbol: "bolt.slash.circle") { [weak self] in
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    try await service.terminate(pid: process.pid, signal: .forceKill)
                    self?.invalidateCache()
                    feedback?.show("已强制结束 \(process.name)（PID \(process.pid)）")
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.onProcessesChanged?()
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            }
        ]

        if matchingNameCount > 1 {
            actions.append(ItemAction(
                id: "process.killAll",
                title: "结束全部 \(matchingNameCount) 个「\(process.name)」",
                presentation: .keepPanelOpen,
                symbol: "xmark.circle.fill"
            ) { [weak self] in
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    let count = try await service.killAll(
                        named: process.name,
                        excludingPID: ProcessInfo.processInfo.processIdentifier,
                        signal: .terminate
                    )
                    self?.invalidateCache()
                    feedback?.show("已结束 \(count) 个 \(process.name) 进程")
                    try? await Task.sleep(for: .milliseconds(120))
                    self?.onProcessesChanged?()
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            })
            actions.append(ItemAction(
                id: "process.forceKillAll",
                title: "强制结束全部「\(process.name)」(SIGKILL)",
                presentation: .keepPanelOpen,
                symbol: "bolt.slash.fill"
            ) { [weak self] in
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    let count = try await service.killAll(
                        named: process.name,
                        excludingPID: ProcessInfo.processInfo.processIdentifier,
                        signal: .forceKill
                    )
                    self?.invalidateCache()
                    feedback?.show("已强制结束 \(count) 个 \(process.name) 进程")
                    try? await Task.sleep(for: .milliseconds(120))
                    self?.onProcessesChanged?()
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            })
        }

        if let clipboard {
            actions.append(ItemAction(id: "process.copyPID", title: "复制 PID", presentation: .dismissThenRun, symbol: "number") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                clipboard.writeString(String(process.pid))
                feedback?.show("已复制 PID \(process.pid)")
            })
            actions.append(ItemAction(id: "process.copyCommand", title: "复制启动命令", presentation: .dismissThenRun, symbol: "doc.on.doc") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                clipboard.writeString(process.commandLine)
                feedback?.show("已复制启动命令")
            })
        }

        let revealPath = process.appBundlePath ?? process.executablePath
        if let revealInFinder, revealPath.hasPrefix("/") {
            actions.append(ItemAction(id: "process.reveal", title: "在访达中显示", presentation: .dismissThenRun, symbol: "folder") {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                revealInFinder(URL(fileURLWithPath: revealPath))
            })
        }

        return SearchItem(
            providerID: id,
            group: .tool,
            title: process.name,
            subtitle: subtitle,
            icon: icon,
            score: score,
            canonicalKey: "process:\(process.pid)",
            actions: actions,
            badge: SearchItemBadge(text: badgeText, tint: badgeTint)
        )
    }

    private func discoveryEntry() -> SearchItem {
        let keyword = keywords.first ?? "kill"
        let prefill = self.prefill
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "结束进程",
            subtitle: "输入 \(keyword) 进程名、PID 或 :端口号，列出并结束运行中的进程",
            icon: .symbol(name: "xmark.octagon", tint: .red),
            score: 1800,
            canonicalKey: "process:entry",
            actions: [ItemAction(id: "process.enter", title: "查看进程", presentation: .keepPanelOpen, symbol: "xmark.octagon") {
                prefill?.prefill(keyword + " ")
            }],
            keyword: keyword
        )
    }

    private func hintItem(title: String, subtitle: String) -> SearchItem {
        let feedback = self.feedback
        return SearchItem(
            providerID: id,
            group: .tool,
            title: title,
            subtitle: subtitle,
            icon: .symbol(name: "xmark.octagon", tint: .gray),
            score: 1000,
            canonicalKey: "process:hint",
            actions: [ItemAction(id: "process.hint", title: "提示", presentation: .keepPanelOpen, symbol: "info.circle") {
                feedback?.show(subtitle)
            }]
        )
    }

    private func parsePortQuery(_ query: String) -> UInt16? {
        guard query.hasPrefix(":") else { return nil }
        let portString = String(query.dropFirst())
        guard !portString.isEmpty, portString.allSatisfy(\.isNumber),
              let port = UInt16(portString), port > 0 else {
            return nil
        }
        return port
    }
}
