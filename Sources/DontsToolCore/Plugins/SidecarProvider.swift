import Foundation

@MainActor
public final class SidecarProvider: ToolProvider {
    public let manifest: ResolvedPluginManifest
    public let id: String
    public let displayName: String
    public let priority: Int
    public let phase: SearchPhase
    public let runsSlowSearchOnEmptyKeywordArgument: Bool
    public private(set) var statusNotice: String?

    private let host: PluginHostContext
    private let transport: any PluginTransport

    public init(
        manifest: ResolvedPluginManifest,
        host: PluginHostContext,
        transport: any PluginTransport
    ) {
        self.manifest = manifest
        self.id = manifest.providerID
        self.displayName = manifest.name
        self.priority = manifest.priority
        self.phase = manifest.phase
        self.runsSlowSearchOnEmptyKeywordArgument = manifest.runsOnEmptyArgument
        self.host = host
        self.transport = transport
    }

    public var keywords: [String] {
        let unavailable = Set(host.unavailableKeywords().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return manifest.keywords.filter { !unavailable.contains($0) }
    }

    public var supportsGlobalSearch: Bool {
        manifest.supportsGlobalSearch || !manifest.globalAliases.isEmpty
    }

    public var isEnabled: Bool {
        get {
            if manifest.origin == .bundled, let legacyID = manifest.legacyProviderID {
                return host.settings.isProviderEnabled(legacyID)
            }
            return host.pluginSettings.isPluginEnabled(manifest.id)
        }
        set {
            if manifest.origin == .bundled, let legacyID = manifest.legacyProviderID {
                host.settings.setProviderEnabled(legacyID, to: newValue)
            } else {
                host.pluginSettings.setPluginEnabled(manifest.id, to: newValue)
            }
        }
    }

    public func homeToolEntry() -> SearchItem? {
        guard isEnabled, let entry = manifest.homeEntry else { return nil }
        return makeEntryItem(entry, score: entry.score)
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        statusNotice = nil
        guard isEnabled, !Task.isCancelled else { return [] }

        switch context.mode {
        case .global:
            let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return [] }

            if !manifest.supportsGlobalSearch {
                guard let entry = manifest.homeEntry,
                      !manifest.globalAliases.isEmpty,
                      manifest.globalAliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) else {
                    return []
                }
                return [makeEntryItem(entry, score: 1800)]
            }

            return await performRemoteSearch(
                mode: "global",
                keyword: nil,
                query: query,
                rawQuery: context.rawQuery,
                frontmostBundleID: context.frontmostBundleID
            )

        case .keyword(let providerID, let keyword, _) where providerID == id:
            let normalizedKeyword = keyword.lowercased()
            guard keywords.contains(normalizedKeyword) else { return [] }
            let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            return await performRemoteSearch(
                mode: "keyword",
                keyword: normalizedKeyword,
                query: query,
                rawQuery: context.rawQuery,
                frontmostBundleID: context.frontmostBundleID
            )

        default:
            return []
        }
    }

    public func shutdown() async {
        await transport.shutdown()
    }

    public func shutdownSync() {
        transport.shutdownSync()
    }

    // MARK: - Private

    private func makeEntryItem(_ entry: ResolvedPluginHomeEntry, score: Double) -> SearchItem {
        let keyword = keywords.first ?? manifest.keywords.first ?? ""
        let prefill = host.prefill
        let pluginManifest = manifest
        return SearchItem(
            providerID: id,
            group: .tool,
            title: entry.title,
            subtitle: entry.subtitle,
            icon: entry.icon,
            score: score,
            canonicalKey: entry.canonicalKey,
            actions: [
                ItemAction(
                    id: "\(manifest.id).enter",
                    title: "打开\(manifest.name)",
                    presentation: .keepPanelOpen,
                    symbol: "arrow.right.circle"
                ) {
                    guard pluginManifest.permissions.contains(.prefill) else {
                        throw PluginHostError.permissionDenied(.prefill, pluginID: pluginManifest.id)
                    }
                    prefill?.prefill(keyword.isEmpty ? "" : "\(keyword) ")
                }
            ],
            keyword: keyword.isEmpty ? nil : keyword
        )
    }

    private func performRemoteSearch(
        mode: String,
        keyword: String?,
        query: String,
        rawQuery: String,
        frontmostBundleID: String?
    ) async -> [SearchItem] {
        let params = PluginSearchParams(
            mode: mode,
            keyword: keyword,
            query: query,
            rawQuery: rawQuery,
            frontmostBundleID: frontmostBundleID,
            preferences: host.resolvePreferences(for: manifest),
            hostContext: host.resolveHostContext(for: manifest)
        )

        do {
            let paramsData = try JSONEncoder().encode(params)
            let responseLine = try await transport.request(
                method: "search",
                paramsData: paramsData,
                timeout: manifest.timeout
            )
            guard isEnabled, !Task.isCancelled else { return [] }
            let rpc = try JSONDecoder().decode(PluginRPCResponse<PluginSearchResultDTO>.self, from: responseLine)
            if let rpcError = rpc.error {
                throw PluginTransportError.rpcError(code: rpcError.code, message: rpcError.message)
            }
            guard let result = rpc.result else {
                throw PluginTransportError.invalidResponse("缺少 result 字段")
            }
            if let notice = result.notice?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty {
                statusNotice = notice
            }
            return result.items.prefix(30).map(mapSearchItem)
        } catch is CancellationError {
            return []
        } catch let transportError as PluginTransportError where transportError == .cancelled {
            return []
        } catch let transportError as PluginTransportError where transportError == .timedOut {
            statusNotice = "\(manifest.name) 响应超时"
            Log.plugin.warning("插件 \(self.manifest.id, privacy: .public) 搜索超时")
            return []
        } catch {
            guard !Task.isCancelled else { return [] }
            statusNotice = error.localizedDescription
            Log.plugin.error("插件 \(self.manifest.id, privacy: .public) 搜索失败：\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func mapSearchItem(_ dto: PluginSearchItemDTO) -> SearchItem {
        let icon = mapIcon(dto.icon)
        let badge = dto.badge.map {
            SearchItemBadge(text: $0.text, tint: PluginTintParser.parse($0.tint))
        }
        let actions = dto.actions.map(mapAction)
        return SearchItem(
            id: dto.id,
            providerID: id,
            group: mapGroup(dto.group),
            title: dto.title,
            subtitle: dto.subtitle,
            icon: icon,
            score: dto.score ?? 1000,
            canonicalKey: dto.canonicalKey,
            actions: actions,
            keyword: dto.keyword,
            badge: badge
        )
    }

    private func mapGroup(_ raw: String?) -> ResultGroup {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "file":
            .file
        case "shortcut":
            .shortcut
        case "web":
            .web
        default:
            .tool
        }
    }

    private func mapFileAction(_ raw: String?) -> FileActionKind? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "reveal":
            .reveal
        case "copyPath":
            .copyPath
        default:
            nil
        }
    }

    private func mapIcon(_ dto: PluginIconDTO?) -> ItemIcon {
        guard let dto else {
            if let iconPath = manifest.iconPath {
                return .image(path: iconPath)
            }
            return .symbol(name: "puzzlepiece.extension", tint: .gray)
        }

        let tint = PluginTintParser.parse(dto.tint)
        switch dto.kind {
        case "symbol":
            return .symbol(name: dto.value, tint: tint)
        case "glyph":
            return .glyph(text: dto.value, tint: tint)
        case "application":
            return .application(path: dto.value)
        case "file":
            return .file(path: dto.value)
        case "image":
            do {
                let resolved = try PluginManifestLoader.resolveContainedPath(dto.value, within: manifest.directoryURL)
                return .image(path: resolved.path)
            } catch {
                Log.plugin.warning("插件 \(self.manifest.id, privacy: .public) 尝试越界读取图标：\(dto.value, privacy: .public)")
                return .symbol(name: "puzzlepiece.extension", tint: tint)
            }
        default:
            return .symbol(name: "puzzlepiece.extension", tint: tint)
        }
    }

    private func mapAction(_ dto: PluginActionDTO) -> ItemAction {
        let presentation: ActionPresentation = switch dto.presentation {
        case "openWindow": .openWindow
        case "keepPanelUntilComplete": .keepPanelUntilComplete
        case "keepPanelOpen": .keepPanelOpen
        default: .dismissThenRun
        }

        let host = self.host
        let manifest = self.manifest
        let transport = self.transport

        return ItemAction(
            id: dto.id,
            title: dto.title,
            presentation: presentation,
            symbol: dto.symbol,
            fileAction: mapFileAction(dto.fileAction)
        ) { [weak self] in
            guard let self, self.isEnabled, !Task.isCancelled else { return }

            if dto.callback == true {
                let params = PluginExecuteParams(
                    actionId: dto.id,
                    payload: dto.payload ?? [:],
                    preferences: host.resolvePreferences(for: manifest),
                    hostContext: host.resolveHostContext(for: manifest)
                )
                let paramsData = try JSONEncoder().encode(params)
                let responseLine = try await transport.request(
                    method: "execute",
                    paramsData: paramsData,
                    timeout: manifest.timeout
                )
                guard self.isEnabled, !Task.isCancelled else { return }
                let rpc = try JSONDecoder().decode(PluginRPCResponse<PluginExecuteResultDTO>.self, from: responseLine)
                if let rpcError = rpc.error {
                    throw PluginTransportError.rpcError(code: rpcError.code, message: rpcError.message)
                }
                guard let result = rpc.result else {
                    throw PluginTransportError.invalidResponse("execute 缺少 result 字段")
                }
                if let errorMessage = result.error?.trimmingCharacters(in: .whitespacesAndNewlines), !errorMessage.isEmpty {
                    if presentation == .keepPanelUntilComplete {
                        throw ActionError.commandFailed(errorMessage)
                    }
                    if let feedback = host.feedback {
                        feedback.show(errorMessage)
                        return
                    }
                    throw ActionError.commandFailed(errorMessage)
                }
                try await host.apply(
                    effect: result.effect,
                    toast: result.toast ?? result.effect?.toast,
                    refresh: result.refresh ?? result.effect?.refresh,
                    recordUsageKey: result.recordUsageKey ?? result.effect?.recordUsageKey,
                    manifest: manifest
                )
            } else {
                try await host.apply(
                    effect: dto.effect,
                    toast: dto.effect?.toast,
                    refresh: dto.effect?.refresh,
                    recordUsageKey: dto.effect?.recordUsageKey,
                    manifest: manifest
                )
            }
        }
    }
}
