import Foundation

@MainActor
public final class TerminalFinderProvider: ToolProvider {
    public static let entryCanonicalKey = "terminal-finder:entry"

    public let id = ProviderID.terminalFinder.rawValue
    public let displayName = "终端与访达"
    public let priority = 200
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }

    public var keywords: [String] {
        let unavailable = Set(unavailableKeywords().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return ["tf", "ft", "term", "终端"].filter { !unavailable.contains($0) }
    }

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    private let settings: SettingsStore
    private let service: any TerminalFinderControlling
    private let prefill: (any QueryPrefilling)?
    private let clipboard: (any ClipboardProviding)?
    private let feedback: (any FeedbackProviding)?
    private let usage: UsageStore?
    private let unavailableKeywords: @MainActor () -> Set<String>

    public init(
        settings: SettingsStore,
        service: any TerminalFinderControlling = SystemTerminalFinderService(),
        prefill: (any QueryPrefilling)? = nil,
        clipboard: (any ClipboardProviding)? = nil,
        feedback: (any FeedbackProviding)? = nil,
        usage: UsageStore? = nil,
        unavailableKeywords: @escaping @MainActor () -> Set<String> = { [] }
    ) {
        self.settings = settings
        self.service = service
        self.prefill = prefill
        self.clipboard = clipboard
        self.feedback = feedback
        self.usage = usage
        self.unavailableKeywords = unavailableKeywords
    }

    public func homeToolEntry() -> SearchItem? {
        guard isEnabled else { return nil }
        return discoveryEntry(score: 896)
    }

    /// Resolves the best terminal to open a directory in (respecting user preference, frontmost terminal, running terminals, and installed order).
    public func preferredTerminal(frontmostBundleID: String? = nil) -> TerminalAppDescriptor? {
        let installed = service.installedTerminals()
        guard !installed.isEmpty else { return nil }

        let configured = settings.preferredTerminalBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty, let matched = installed.first(where: { $0.matches(bundleID: configured) }) {
            return matched
        }
        if let frontmostBundleID, let matched = installed.first(where: { $0.matches(bundleID: frontmostBundleID) }) {
            return matched
        }
        let running = service.runningTerminalBundleIDs()
        if let firstRunning = running.first,
           let matched = installed.first(where: { $0.matches(bundleID: firstRunning) }) {
            return matched
        }
        return installed.first
    }

    /// Shared helper so FileProvider / QuickOpenProvider / IDEProjectProvider can open any path in the preferred terminal.
    public func openPathInPreferredTerminal(_ url: URL) async throws {
        guard let target = preferredTerminal() else {
            throw TerminalFinderError.terminalNotInstalled("终端")
        }
        try await service.openInTerminal(directory: url, terminalBundleID: target.bundleID)
        usage?.recordUse(of: Self.entryCanonicalKey)
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled, !Task.isCancelled else { return [] }

        switch context.mode {
        case .global:
            let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return [] }
            let aliases = [
                "tf", "ft", "term", "terminal", "finder", "terminal finder",
                "终端", "访达", "终端与访达", "访达转终端", "终端转访达",
                "ghostty", "otty", "warp", "iterm", "iterm2"
            ]
            guard aliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) else {
                return []
            }
            return [discoveryEntry(score: 1800)]

        case .keyword(let providerID, let keyword, _) where providerID == id:
            guard keywords.contains(keyword.lowercased()) else { return [] }
            let argument = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let installed = service.installedTerminals()
            let primaryTerminal = preferredTerminal(frontmostBundleID: context.frontmostBundleID)

            // Direct path argument, e.g. `tf ~/Desktop` or `tf /tmp`
            if let pathURL = parseDirectoryArgument(argument) {
                return [makeOpenPathItem(pathURL, primaryTerminal: primaryTerminal, installed: installed)]
            }

            let frontmost = context.frontmostBundleID
            let isFromFinder = frontmost?.caseInsensitiveCompare(TerminalAppCatalog.finderBundleID) == .orderedSame
            let frontmostTerminal = frontmost.flatMap { id in installed.first(where: { $0.matches(bundleID: id) }) }

            var items: [SearchItem] = []

            // 1. Finder -> Terminal
            let finderToTerminalScore: Double = isFromFinder ? 3200 : (frontmostTerminal != nil ? 2000 : 3000)
            items.append(makeFinderToTerminalItem(
                primaryTerminal: primaryTerminal,
                installed: installed,
                score: finderToTerminalScore,
                isContextualPrimary: isFromFinder
            ))

            // 2. Terminal -> Finder
            let terminalToFinderScore: Double = frontmostTerminal != nil ? 3200 : (isFromFinder ? 2000 : 2900)
            items.append(makeTerminalToFinderItem(
                preferredTerminalBundleID: frontmostTerminal?.bundleID ?? primaryTerminal?.bundleID,
                terminalDisplayName: frontmostTerminal?.displayName,
                score: terminalToFinderScore,
                isContextualPrimary: frontmostTerminal != nil
            ))

            // 3. Copy Finder Path / Copy Terminal Path
            if clipboard != nil {
                items.append(makeCopyFinderPathItem(score: isFromFinder ? 2600 : 2200))
                items.append(makeCopyTerminalPathItem(
                    preferredTerminalBundleID: frontmostTerminal?.bundleID ?? primaryTerminal?.bundleID,
                    terminalDisplayName: frontmostTerminal?.displayName,
                    score: frontmostTerminal != nil ? 2600 : 2100
                ))
            }

            // 4. Explicit per-terminal entries if user typed a terminal name (e.g. `tf warp`, `tf ghostty`, `tf iterm`).
            if !argument.isEmpty {
                for terminal in installed {
                    if terminalMatches(terminal, query: argument), terminal.bundleID != primaryTerminal?.bundleID {
                        items.append(makeFinderToTerminalItem(
                            primaryTerminal: terminal,
                            installed: installed,
                            score: 3150,
                            isContextualPrimary: false
                        ))
                    }
                }
                let filtered = items.filter { item in
                    FuzzyMatcher.score(query: argument, candidate: item.title) != nil
                        || (item.subtitle.map { FuzzyMatcher.score(query: argument, candidate: $0) != nil } ?? false)
                }
                if !filtered.isEmpty {
                    return filtered.sorted { $0.score > $1.score }
                }
                return [hintItem(
                    title: "没有匹配的终端与访达操作",
                    subtitle: "可输入访达、终端、复制、Ghostty / Warp / iTerm2，或直接输入目录路径如 ~/Desktop"
                )]
            }

            return items.sorted { $0.score > $1.score }

        default:
            return []
        }
    }

    // MARK: - Item Builders

    private func makeFinderToTerminalItem(
        primaryTerminal: TerminalAppDescriptor?,
        installed: [TerminalAppDescriptor],
        score: Double,
        isContextualPrimary: Bool
    ) -> SearchItem {
        let settings = self.settings
        let service = self.service
        let clipboard = self.clipboard
        let feedback = self.feedback
        let usage = self.usage
        let providerID = id

        let targetName = primaryTerminal?.displayName ?? "终端"
        let icon: ItemIcon = primaryTerminal?.appPath.map(ItemIcon.application(path:))
            ?? .symbol(name: "terminal", tint: .teal)

        var actions: [ItemAction] = []
        if let primaryTerminal {
            actions.append(ItemAction(
                id: "tf.finderToTerminal.\(primaryTerminal.bundleID)",
                title: "在 \(primaryTerminal.displayName) 中打开访达目录",
                presentation: .openWindow,
                symbol: "terminal"
            ) {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    let dir = try await service.currentFinderDirectory()
                    try await service.openInTerminal(directory: dir, terminalBundleID: primaryTerminal.bundleID)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            })
        } else {
            actions.append(ItemAction(
                id: "tf.finderToTerminal.missing",
                title: "打开终端",
                presentation: .keepPanelOpen,
                symbol: "terminal"
            ) {
                feedback?.show(TerminalFinderError.terminalNotInstalled("终端").localizedDescription)
            })
        }

        for other in installed where other.bundleID != primaryTerminal?.bundleID {
            actions.append(ItemAction(
                id: "tf.finderToTerminal.\(other.bundleID)",
                title: "改用 \(other.displayName) 打开",
                presentation: .openWindow,
                symbol: "terminal"
            ) {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    let dir = try await service.currentFinderDirectory()
                    try await service.openInTerminal(directory: dir, terminalBundleID: other.bundleID)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            })
        }

        if let clipboard {
            actions.append(ItemAction(
                id: "tf.copyFinderPath",
                title: "复制当前访达路径",
                presentation: .dismissThenRun,
                symbol: "doc.on.doc"
            ) {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    let dir = try await service.currentFinderDirectory()
                    clipboard.writeString(dir.path)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                    feedback?.show("已复制访达路径：\(dir.path)")
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            })
        }

        return SearchItem(
            providerID: id,
            group: .tool,
            title: "在 \(targetName) 中打开当前访达目录",
            subtitle: installed.count > 1 ? "访达 → \(targetName)（⌘K 可切换其他已安装终端）" : "访达 → \(targetName)（选中文件夹或当前窗口目录）",
            icon: icon,
            score: score,
            canonicalKey: "terminal-finder:finder-to-\(primaryTerminal?.bundleID ?? "default")",
            actions: actions,
            badge: isContextualPrimary ? SearchItemBadge(text: "当前访达", tint: .blue) : SearchItemBadge(text: "访达→终端", tint: .teal)
        )
    }

    private func makeTerminalToFinderItem(
        preferredTerminalBundleID: String?,
        terminalDisplayName: String?,
        score: Double,
        isContextualPrimary: Bool
    ) -> SearchItem {
        let settings = self.settings
        let service = self.service
        let clipboard = self.clipboard
        let feedback = self.feedback
        let usage = self.usage
        let providerID = id

        let label = terminalDisplayName ?? "终端"
        var actions: [ItemAction] = [
            ItemAction(
                id: "tf.terminalToFinder",
                title: "在访达中打开\(label)目录",
                presentation: .openWindow,
                symbol: "folder"
            ) {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    let dir = try await service.currentTerminalDirectory(preferredBundleID: preferredTerminalBundleID)
                    try await service.openInFinder(directory: dir)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            }
        ]
        if let clipboard {
            actions.append(ItemAction(
                id: "tf.copyTerminalPath",
                title: "复制\(label)当前路径",
                presentation: .dismissThenRun,
                symbol: "doc.on.doc"
            ) {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    let dir = try await service.currentTerminalDirectory(preferredBundleID: preferredTerminalBundleID)
                    clipboard.writeString(dir.path)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                    feedback?.show("已复制终端路径：\(dir.path)")
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            })
        }

        return SearchItem(
            providerID: id,
            group: .tool,
            title: "在访达中打开\(label)当前目录",
            subtitle: "\(label) → 访达（自动识别活跃 Shell 工作目录）",
            icon: .symbol(name: "folder", tint: .blue),
            score: score,
            canonicalKey: "terminal-finder:terminal-to-finder",
            actions: actions,
            badge: isContextualPrimary ? SearchItemBadge(text: "当前终端", tint: .teal) : SearchItemBadge(text: "终端→访达", tint: .blue)
        )
    }

    private func makeCopyFinderPathItem(score: Double) -> SearchItem {
        let settings = self.settings
        let service = self.service
        let clipboard = self.clipboard
        let feedback = self.feedback
        let usage = self.usage
        let providerID = id

        return SearchItem(
            providerID: id,
            group: .tool,
            title: "复制当前访达路径",
            subtitle: "读取访达当前窗口或所选目录路径并复制到剪贴板",
            icon: .symbol(name: "doc.on.doc", tint: .gray),
            score: score,
            canonicalKey: "terminal-finder:copy-finder-path",
            actions: [
                ItemAction(id: "tf.copyFinderPath.primary", title: "复制路径", presentation: .dismissThenRun, symbol: "doc.on.doc") {
                    guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                    do {
                        let dir = try await service.currentFinderDirectory()
                        clipboard?.writeString(dir.path)
                        usage?.recordUse(of: Self.entryCanonicalKey)
                        feedback?.show("已复制访达路径：\(dir.path)")
                    } catch {
                        feedback?.show(error.localizedDescription)
                    }
                }
            ]
        )
    }

    private func makeCopyTerminalPathItem(
        preferredTerminalBundleID: String?,
        terminalDisplayName: String?,
        score: Double
    ) -> SearchItem {
        let settings = self.settings
        let service = self.service
        let clipboard = self.clipboard
        let feedback = self.feedback
        let usage = self.usage
        let providerID = id
        let label = terminalDisplayName ?? "终端"

        return SearchItem(
            providerID: id,
            group: .tool,
            title: "复制\(label)当前路径",
            subtitle: "读取\(label)活跃 Shell 工作目录并复制到剪贴板",
            icon: .symbol(name: "doc.on.doc", tint: .gray),
            score: score,
            canonicalKey: "terminal-finder:copy-terminal-path",
            actions: [
                ItemAction(id: "tf.copyTerminalPath.primary", title: "复制路径", presentation: .dismissThenRun, symbol: "doc.on.doc") {
                    guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                    do {
                        let dir = try await service.currentTerminalDirectory(preferredBundleID: preferredTerminalBundleID)
                        clipboard?.writeString(dir.path)
                        usage?.recordUse(of: Self.entryCanonicalKey)
                        feedback?.show("已复制终端路径：\(dir.path)")
                    } catch {
                        feedback?.show(error.localizedDescription)
                    }
                }
            ]
        )
    }

    private func makeOpenPathItem(
        _ directory: URL,
        primaryTerminal: TerminalAppDescriptor?,
        installed: [TerminalAppDescriptor]
    ) -> SearchItem {
        let settings = self.settings
        let service = self.service
        let clipboard = self.clipboard
        let feedback = self.feedback
        let usage = self.usage
        let providerID = id

        let targetName = primaryTerminal?.displayName ?? "终端"
        let icon: ItemIcon = primaryTerminal?.appPath.map(ItemIcon.application(path:))
            ?? .symbol(name: "terminal", tint: .teal)

        var actions: [ItemAction] = []
        if let primaryTerminal {
            actions.append(ItemAction(
                id: "tf.openPath.\(primaryTerminal.bundleID)",
                title: "在 \(primaryTerminal.displayName) 中打开",
                presentation: .openWindow,
                symbol: "terminal"
            ) {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    try await service.openInTerminal(directory: directory, terminalBundleID: primaryTerminal.bundleID)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            })
        }
        for other in installed where other.bundleID != primaryTerminal?.bundleID {
            actions.append(ItemAction(
                id: "tf.openPath.\(other.bundleID)",
                title: "改用 \(other.displayName) 打开",
                presentation: .openWindow,
                symbol: "terminal"
            ) {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                do {
                    try await service.openInTerminal(directory: directory, terminalBundleID: other.bundleID)
                    usage?.recordUse(of: Self.entryCanonicalKey)
                } catch {
                    feedback?.show(error.localizedDescription)
                }
            })
        }
        actions.append(ItemAction(
            id: "tf.openPath.finder",
            title: "在访达中打开",
            presentation: .openWindow,
            symbol: "folder"
        ) {
            guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
            do {
                try await service.openInFinder(directory: directory)
                usage?.recordUse(of: Self.entryCanonicalKey)
            } catch {
                feedback?.show(error.localizedDescription)
            }
        })
        if let clipboard {
            actions.append(ItemAction(
                id: "tf.openPath.copy",
                title: "复制路径",
                presentation: .dismissThenRun,
                symbol: "doc.on.doc"
            ) {
                guard settings.isProviderEnabled(providerID), !Task.isCancelled else { return }
                clipboard.writeString(directory.path)
                usage?.recordUse(of: Self.entryCanonicalKey)
                feedback?.show("已复制路径：\(directory.path)")
            })
        }

        return SearchItem(
            providerID: id,
            group: .tool,
            title: "在 \(targetName) 中打开 \(directory.lastPathComponent)",
            subtitle: directory.path,
            icon: icon,
            score: 3300,
            canonicalKey: "terminal-finder:path:\(directory.path)",
            actions: actions,
            badge: SearchItemBadge(text: "目录", tint: .teal)
        )
    }

    private func discoveryEntry(score: Double) -> SearchItem {
        let keyword = keywords.first ?? "tf"
        let prefill = self.prefill
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "终端与访达",
            subtitle: "输入 \(keyword) 在访达与 Ghostty / Warp / iTerm2 / 终端之间双向跳转",
            icon: .symbol(name: "terminal", tint: .teal),
            score: score,
            canonicalKey: Self.entryCanonicalKey,
            actions: [ItemAction(id: "tf.enter", title: "打开终端与访达", presentation: .keepPanelOpen, symbol: "terminal") {
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
            icon: .symbol(name: "terminal", tint: .gray),
            score: 1000,
            canonicalKey: "terminal-finder:hint",
            actions: [ItemAction(id: "tf.hint", title: "提示", presentation: .keepPanelOpen, symbol: "info.circle") {
                feedback?.show(subtitle)
            }]
        )
    }

    private func terminalMatches(_ terminal: TerminalAppDescriptor, query: String) -> Bool {
        if FuzzyMatcher.score(query: query, candidate: terminal.displayName) != nil { return true }
        return terminal.aliases.contains { FuzzyMatcher.score(query: query, candidate: $0) != nil }
    }

    private func parseDirectoryArgument(_ argument: String) -> URL? {
        guard argument.hasPrefix("/") || argument.hasPrefix("~") else { return nil }
        let expanded = (argument as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}
