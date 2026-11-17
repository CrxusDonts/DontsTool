import Foundation

@MainActor
public final class SearchCoordinator {
    public enum Status: Equatable, Sendable {
        case idle
        case searchingFiles
        case message(String)
    }

    public struct Update {
        public let items: [SearchItem]
        public let status: Status
    }

    public var onUpdate: ((Update) -> Void)?

    private let registry: ToolRegistry
    private let usage: UsageStore?
    private let slowDelay: Duration
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    public init(registry: ToolRegistry, usage: UsageStore? = nil, slowDelay: Duration = .milliseconds(120)) {
        self.registry = registry
        self.usage = usage
        self.slowDelay = slowDelay
    }

    public func submit(_ rawQuery: String, frontmostBundleID: String? = nil) {
        generation += 1
        let currentGeneration = generation
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.run(
                rawQuery: rawQuery,
                generation: currentGeneration,
                frontmostBundleID: frontmostBundleID
            )
        }
    }

    public func cancel() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
    }

    func waitForPendingSearch() async {
        await searchTask?.value
    }

    private func run(rawQuery: String, generation: Int, frontmostBundleID: String?) async {
        let routes = registry.enabledKeywordRoutes()
        let context = QueryParser.parse(
            rawQuery,
            routes: routes,
            frontmostBundleID: frontmostBundleID
        )
        let enabled = registry.enabledProviders

        let selected: [ToolProvider]
        switch context.mode {
        case .keyword(let providerID, _, let argument):
            selected = enabled.filter {
                $0.id == providerID || (argument.isEmpty && $0.id == ProviderID.app.rawValue)
            }
        case .global:
            selected = enabled.filter(\.supportsGlobalSearch)
        }

        let fastProviders = selected.filter { $0.phase == .fast }
        let slowProviders = context.query.isEmpty ? [] : selected.filter { $0.phase == .slow }

        var fastItems: [SearchItem] = []
        var fastNotice: String?
        for provider in fastProviders {
            let items = await provider.search(context)
            guard isCurrent(generation) else { return }
            fastItems.append(contentsOf: items)
            if let providerNotice = provider.statusNotice { fastNotice = providerNotice }
        }

        let fastMerged = merge(fastItems, context: context, allowWeb: slowProviders.isEmpty)
        publish(
            fastMerged,
            status: slowProviders.isEmpty ? (fastNotice.map(Status.message) ?? .idle) : .searchingFiles,
            generation: generation
        )

        guard !slowProviders.isEmpty else { return }
        do {
            try await Task.sleep(for: slowDelay)
        } catch {
            return
        }
        guard isCurrent(generation) else { return }

        var slowItems: [SearchItem] = []
        var notice: String?
        for provider in slowProviders {
            let items = await provider.search(context)
            guard isCurrent(generation) else { return }
            slowItems.append(contentsOf: items)
            if let providerNotice = provider.statusNotice {
                notice = providerNotice
            }
        }

        let merged = merge(fastItems + slowItems, context: context, allowWeb: true)
        publish(merged, status: (notice ?? fastNotice).map(Status.message) ?? .idle, generation: generation)
    }

    private func merge(_ items: [SearchItem], context: SearchContext, allowWeb: Bool) -> [SearchItem] {
        var bestByKey: [String: SearchItem] = [:]
        var order: [String] = []

        for item in items {
            if let existing = bestByKey[item.canonicalKey] {
                if item.score > existing.score {
                    bestByKey[item.canonicalKey] = item
                }
            } else {
                bestByKey[item.canonicalKey] = item
                order.append(item.canonicalKey)
            }
        }

        var merged = order.compactMap { bestByKey[$0] }

        if case .global = context.mode {
            if context.query.isEmpty || !allowWeb {
                merged.removeAll { $0.group == .web }
            } else if merged.contains(where: { $0.group != .web }) {
                merged.removeAll { $0.group == .web }
            }
        }

        var toolRanks: [String: Double] = [:]
        var latestTool: String?
        if context.mode == .global, context.query.isEmpty, let usage {
            let rankedAt = Date()
            var latestUse = Date.distantPast
            for item in merged where item.group == .tool {
                let key = item.canonicalKey
                guard let record = usage.record(for: key), record.count > 0 else { continue }
                toolRanks[key] = usage.boost(for: key, now: rankedAt)
                if record.lastUsed > latestUse {
                    latestUse = record.lastUsed
                    latestTool = key
                }
            }
        }

        merged.sort {
            if $0.group != $1.group { return $0.group < $1.group }
            let lhsIsLatest = $0.canonicalKey == latestTool
            let rhsIsLatest = $1.canonicalKey == latestTool
            if lhsIsLatest != rhsIsLatest { return lhsIsLatest }
            let lhsRank = toolRanks[$0.canonicalKey, default: 0]
            let rhsRank = toolRanks[$1.canonicalKey, default: 0]
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        let caps: [ResultGroup: Int] = [.app: 8, .tool: 8, .knowledge: 8, .file: 12, .web: 1, .shortcut: context.mode == .global ? 8 : 5000]
        var counts: [ResultGroup: Int] = [:]
        return merged.filter { item in
            let count = counts[item.group, default: 0]
            guard count < caps[item.group, default: 0] else { return false }
            counts[item.group] = count + 1
            return true
        }
    }

    private func isCurrent(_ expected: Int) -> Bool {
        generation == expected && !Task.isCancelled
    }

    private func publish(_ items: [SearchItem], status: Status, generation: Int) {
        guard isCurrent(generation) else { return }
        onUpdate?(Update(items: items, status: status))
    }
}
