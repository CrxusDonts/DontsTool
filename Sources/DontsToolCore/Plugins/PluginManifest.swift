import Foundation

public enum PluginOrigin: String, Equatable, Sendable {
    case bundled
    case user
}

public enum PluginPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case clipboardWrite = "clipboard.write"
    case openURL
    case openFile
    case revealInFinder
    case openTerminal
    case openApplication
    case openAI
    case prefill
    case toast
    case secrets
    case refresh

    public var displayName: String {
        switch self {
        case .clipboardWrite: "写入剪贴板"
        case .openURL: "打开网页链接"
        case .openFile: "打开本地文件"
        case .revealInFinder: "在访达中显示"
        case .openTerminal: "在首选终端打开"
        case .openApplication: "启动本机应用"
        case .openAI: "调用宿主 AI 对话窗口"
        case .prefill: "回填搜索框"
        case .toast: "显示通知提示"
        case .secrets: "读取插件专用钥匙串密钥"
        case .refresh: "刷新当前搜索结果"
        }
    }
}

public struct PluginVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public static func parse(_ raw: String) -> PluginVersion? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let plusIndex = text.firstIndex(of: "+") {
            text = String(text[..<plusIndex])
        }
        let core: String
        let prerelease: String?
        if let dashIndex = text.firstIndex(of: "-") {
            core = String(text[..<dashIndex])
            let pre = String(text[text.index(after: dashIndex)...])
            guard !pre.isEmpty else { return nil }
            prerelease = pre
        } else {
            core = text
            prerelease = nil
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0",
                  let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        return PluginVersion(
            major: numbers[0],
            minor: numbers[1],
            patch: numbers.count == 3 ? numbers[2] : 0,
            prerelease: prerelease
        )
    }

    public static func < (lhs: PluginVersion, rhs: PluginVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case let (lPre?, rPre?):
            let lParts = lPre.split(separator: ".", omittingEmptySubsequences: false)
            let rParts = rPre.split(separator: ".", omittingEmptySubsequences: false)
            for (lPart, rPart) in zip(lParts, rParts) where lPart != rPart {
                if let lNum = Int(lPart), let rNum = Int(rPart) {
                    return lNum < rNum
                }
                return lPart < rPart
            }
            return lParts.count < rParts.count
        }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let next = parse(candidate), let installed = parse(current) else {
            return false
        }
        return installed < next
    }

    public static func isSatisfied(minimum required: String, by current: String) -> Bool {
        guard let minimum = parse(required), let actual = parse(current) else {
            return false
        }
        return actual >= minimum
    }
}

public enum PluginRuntimeMode: String, Codable, Equatable, Sendable {
    case oneshot
    case daemon
}

public struct PluginRuntimeSpec: Codable, Equatable, Sendable {
    public let mode: PluginRuntimeMode
    public let command: [String]
    public let timeoutMs: Int?
    public let idleTimeoutSec: Int?

    public init(
        mode: PluginRuntimeMode,
        command: [String],
        timeoutMs: Int? = nil,
        idleTimeoutSec: Int? = nil
    ) {
        self.mode = mode
        self.command = command
        self.timeoutMs = timeoutMs
        self.idleTimeoutSec = idleTimeoutSec
    }
}

public struct PluginHomeEntrySpec: Codable, Equatable, Sendable {
    public let canonicalKey: String
    public let title: String
    public let subtitle: String?
    public let symbol: String?
    public let image: String?
    public let tint: String?
    public let score: Double?

    public init(
        canonicalKey: String,
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        image: String? = nil,
        tint: String? = nil,
        score: Double? = nil
    ) {
        self.canonicalKey = canonicalKey
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.image = image
        self.tint = tint
        self.score = score
    }
}

public struct PluginPreferenceSpec: Codable, Equatable, Sendable {
    public let key: String
    public let type: String
    public let title: String
    public let required: Bool?
    public let defaultValue: String?

    public init(
        key: String,
        type: String,
        title: String,
        required: Bool? = nil,
        defaultValue: String? = nil
    ) {
        self.key = key
        self.type = type
        self.title = title
        self.required = required
        self.defaultValue = defaultValue
    }
}

public struct PluginUISpec: Codable, Equatable, Sendable {
    public let entry: String?

    public init(entry: String? = nil) {
        self.entry = entry
    }
}

public struct PluginManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let description: String?
    public let minHostVersion: String?
    public let keywords: [String]
    public let supportsGlobalSearch: Bool?
    public let globalAliases: [String]?
    public let phase: String?
    public let runsOnEmptyArgument: Bool?
    public let priority: Int?
    public let icon: String?
    public let legacyProviderID: String?
    public let homeEntry: PluginHomeEntrySpec?
    public let runtime: PluginRuntimeSpec
    public let permissions: [PluginPermission]?
    public let preferences: [PluginPreferenceSpec]?
    public let ui: PluginUISpec?

    public init(
        schemaVersion: Int = 1,
        id: String,
        name: String,
        version: String,
        description: String? = nil,
        minHostVersion: String? = nil,
        keywords: [String],
        supportsGlobalSearch: Bool? = nil,
        globalAliases: [String]? = nil,
        phase: String? = nil,
        runsOnEmptyArgument: Bool? = nil,
        priority: Int? = nil,
        icon: String? = nil,
        legacyProviderID: String? = nil,
        homeEntry: PluginHomeEntrySpec? = nil,
        runtime: PluginRuntimeSpec,
        permissions: [PluginPermission]? = nil,
        preferences: [PluginPreferenceSpec]? = nil,
        ui: PluginUISpec? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.minHostVersion = minHostVersion
        self.keywords = keywords
        self.supportsGlobalSearch = supportsGlobalSearch
        self.globalAliases = globalAliases
        self.phase = phase
        self.runsOnEmptyArgument = runsOnEmptyArgument
        self.priority = priority
        self.icon = icon
        self.legacyProviderID = legacyProviderID
        self.homeEntry = homeEntry
        self.runtime = runtime
        self.permissions = permissions
        self.preferences = preferences
        self.ui = ui
    }
}

public struct ResolvedPluginHomeEntry: Equatable, Sendable {
    public let canonicalKey: String
    public let title: String
    public let subtitle: String?
    public let icon: ItemIcon
    public let score: Double

    public init(canonicalKey: String, title: String, subtitle: String?, icon: ItemIcon, score: Double) {
        self.canonicalKey = canonicalKey
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.score = score
    }
}

public struct ResolvedPluginManifest: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String?
    public let minHostVersion: String?
    public let origin: PluginOrigin
    public let directoryURL: URL
    public let keywords: [String]
    public let supportsGlobalSearch: Bool
    public let globalAliases: [String]
    public let phase: SearchPhase
    public let runsOnEmptyArgument: Bool
    public let priority: Int
    public let iconPath: String?
    public let legacyProviderID: String?
    public let homeEntry: ResolvedPluginHomeEntry?
    public let runtimeMode: PluginRuntimeMode
    public let executableURL: URL
    public let arguments: [String]
    public let timeout: Duration
    public let idleTimeout: Duration
    public let permissions: Set<PluginPermission>
    public let preferences: [PluginPreferenceSpec]
    public let uiEntryURL: URL?

    public var providerID: String { "plugin.\(id)" }
}

public enum PluginManifestError: LocalizedError, Equatable, Sendable {
    case unreadableManifest(String)
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case invalidPluginID(String)
    case emptyField(String)
    case emptyKeywords
    case invalidPhase(String)
    case emptyCommand
    case forbiddenForUserPlugin(String)
    case missingHelpersDirectory
    case pathTraversal(String)
    case executableNotFound(String)
    case invalidMinHostVersion(String)
    case incompatibleHostVersion(required: String, current: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableManifest(let detail): "无法读取插件清单：\(detail)"
        case .invalidJSON(let detail): "插件清单 JSON 格式无效：\(detail)"
        case .unsupportedSchemaVersion(let version): "不支持的插件清单版本：\(version)"
        case .invalidPluginID(let id): "插件 ID 格式不合法：\(id)"
        case .emptyField(let field): "插件清单缺少必填字段：\(field)"
        case .emptyKeywords: "插件必须声明至少一个触发关键词"
        case .invalidPhase(let phase): "无效的搜索阶段声明：\(phase)"
        case .emptyCommand: "插件 runtime.command 不能为空"
        case .forbiddenForUserPlugin(let field): "外部用户插件不允许声明保留字段 \(field)"
        case .missingHelpersDirectory: "宿主未配置 Helpers 目录，无法解析官方内置插件"
        case .pathTraversal(let path): "检测到越界路径：\(path)"
        case .executableNotFound(let path): "插件可执行入口不存在或无执行权限：\(path)"
        case .invalidMinHostVersion(let version): "插件声明的最低宿主版本格式无效：\(version)"
        case .incompatibleHostVersion(let required, let current): "插件需要 DontsTool \(required) 或更高版本（当前 \(current)）"
        }
    }
}

public enum PluginManifestLoader {
    private static let hostHelpersPrefix = "$HOST_HELPERS/"

    public static func isValidPluginID(_ id: String) -> Bool {
        guard id.count >= 2, id.count <= 64 else { return false }
        guard let first = id.unicodeScalars.first, isLowerAlphaNumeric(first) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            isLowerAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    public static func resolveContainedPath(_ relativePath: String, within baseDirectory: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~") else {
            throw PluginManifestError.pathTraversal(relativePath)
        }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(".."), !segments.contains("") else {
            throw PluginManifestError.pathTraversal(relativePath)
        }

        let normalizedBase = baseDirectory.standardizedFileURL
        let normalizedTarget = normalizedBase.appendingPathComponent(trimmed).standardizedFileURL
        guard normalizedTarget.path.hasPrefix(normalizedBase.path + "/") else {
            throw PluginManifestError.pathTraversal(relativePath)
        }

        let resolvedBase = normalizedBase.resolvingSymlinksInPath()
        let resolvedTarget = normalizedTarget.resolvingSymlinksInPath()
        guard resolvedTarget.path.hasPrefix(resolvedBase.path + "/") else {
            throw PluginManifestError.pathTraversal(relativePath)
        }
        return normalizedTarget
    }

    public static func load(
        from pluginDirectory: URL,
        origin: PluginOrigin,
        helpersDirectory: URL? = nil,
        hostVersion: String? = nil
    ) throws -> ResolvedPluginManifest {
        let manifestURL = pluginDirectory.appendingPathComponent("manifest.json")
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PluginManifestError.unreadableManifest(error.localizedDescription)
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PluginManifestError.invalidJSON(error.localizedDescription)
        }

        return try validate(
            manifest,
            in: pluginDirectory,
            origin: origin,
            helpersDirectory: helpersDirectory,
            hostVersion: hostVersion
        )
    }

    public static func validate(
        _ manifest: PluginManifest,
        in pluginDirectory: URL,
        origin: PluginOrigin,
        helpersDirectory: URL? = nil,
        hostVersion: String? = nil
    ) throws -> ResolvedPluginManifest {
        guard manifest.schemaVersion == 1 else {
            throw PluginManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
        }

        let trimmedID = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPluginID(trimmedID) else {
            throw PluginManifestError.invalidPluginID(manifest.id)
        }

        let name = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw PluginManifestError.emptyField("name")
        }

        let version = manifest.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw PluginManifestError.emptyField("version")
        }

        let rawMinHostVersion = manifest.minHostVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMinHostVersion = (rawMinHostVersion?.isEmpty == false) ? rawMinHostVersion : nil
        if let resolvedMinHostVersion {
            guard PluginVersion.parse(resolvedMinHostVersion) != nil else {
                throw PluginManifestError.invalidMinHostVersion(resolvedMinHostVersion)
            }
            if let currentHost = hostVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
               !currentHost.isEmpty,
               !PluginVersion.isSatisfied(minimum: resolvedMinHostVersion, by: currentHost) {
                throw PluginManifestError.incompatibleHostVersion(
                    required: resolvedMinHostVersion,
                    current: currentHost
                )
            }
        }

        let normalizedKeywords = normalizeUniqueList(manifest.keywords.map { $0.lowercased() })
        guard !normalizedKeywords.isEmpty else {
            throw PluginManifestError.emptyKeywords
        }

        let legacyID = manifest.legacyProviderID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLegacyID = (legacyID?.isEmpty == false) ? legacyID : nil
        if origin == .user, resolvedLegacyID != nil {
            throw PluginManifestError.forbiddenForUserPlugin("legacyProviderID")
        }

        let phase: SearchPhase
        switch manifest.phase?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "slow":
            phase = .slow
        case "fast":
            phase = .fast
        case let invalid?:
            throw PluginManifestError.invalidPhase(invalid)
        }

        guard let rawCommandHead = manifest.runtime.command.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCommandHead.isEmpty else {
            throw PluginManifestError.emptyCommand
        }

        let executableURL: URL
        if rawCommandHead.hasPrefix(hostHelpersPrefix) {
            guard origin == .bundled else {
                throw PluginManifestError.forbiddenForUserPlugin("$HOST_HELPERS")
            }
            guard let helpersDirectory else {
                throw PluginManifestError.missingHelpersDirectory
            }
            let suffix = String(rawCommandHead.dropFirst(hostHelpersPrefix.count))
            executableURL = try resolveContainedPath(suffix, within: helpersDirectory)
        } else if rawCommandHead.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: rawCommandHead).standardizedFileURL
        } else {
            executableURL = try resolveContainedPath(rawCommandHead, within: pluginDirectory)
        }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw PluginManifestError.executableNotFound(executableURL.path)
        }

        let iconPath: String?
        if let rawIcon = manifest.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !rawIcon.isEmpty {
            iconPath = try resolveContainedPath(rawIcon, within: pluginDirectory).path
        } else {
            iconPath = nil
        }

        let resolvedHomeEntry: ResolvedPluginHomeEntry?
        if let entry = manifest.homeEntry {
            let entryTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalKey = entry.canonicalKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonicalKey.isEmpty else { throw PluginManifestError.emptyField("homeEntry.canonicalKey") }
            guard !entryTitle.isEmpty else { throw PluginManifestError.emptyField("homeEntry.title") }
            let tint = PluginTintParser.parse(entry.tint)
            let entryIcon: ItemIcon
            if let img = entry.image?.trimmingCharacters(in: .whitespacesAndNewlines), !img.isEmpty {
                let resolvedPath = try resolveContainedPath(img, within: pluginDirectory).path
                entryIcon = .image(path: resolvedPath)
            } else if let symbol = entry.symbol?.trimmingCharacters(in: .whitespacesAndNewlines), !symbol.isEmpty {
                entryIcon = .symbol(name: symbol, tint: tint)
            } else if let iconPath {
                entryIcon = .image(path: iconPath)
            } else {
                entryIcon = .symbol(name: "puzzlepiece.extension", tint: tint)
            }
            resolvedHomeEntry = ResolvedPluginHomeEntry(
                canonicalKey: canonicalKey,
                title: entryTitle,
                subtitle: entry.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                icon: entryIcon,
                score: entry.score ?? 850
            )
        } else {
            resolvedHomeEntry = nil
        }

        let uiEntryURL: URL?
        if let uiEntry = manifest.ui?.entry?.trimmingCharacters(in: .whitespacesAndNewlines), !uiEntry.isEmpty {
            uiEntryURL = try resolveContainedPath(uiEntry, within: pluginDirectory)
        } else {
            uiEntryURL = nil
        }

        let clampedPriority: Int
        switch origin {
        case .bundled:
            clampedPriority = min(max(manifest.priority ?? 100, 1), 200)
        case .user:
            clampedPriority = min(max(manifest.priority ?? 30, 1), 50)
        }

        let clampedTimeoutMs = min(max(manifest.runtime.timeoutMs ?? 1500, 100), 2000)
        let clampedIdleTimeoutSec = min(max(manifest.runtime.idleTimeoutSec ?? 300, 10), 3600)

        return ResolvedPluginManifest(
            id: trimmedID,
            name: name,
            version: version,
            description: manifest.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            minHostVersion: resolvedMinHostVersion,
            origin: origin,
            directoryURL: pluginDirectory.standardizedFileURL,
            keywords: normalizedKeywords,
            supportsGlobalSearch: manifest.supportsGlobalSearch ?? false,
            globalAliases: normalizeUniqueList(manifest.globalAliases ?? []),
            phase: phase,
            runsOnEmptyArgument: manifest.runsOnEmptyArgument ?? false,
            priority: clampedPriority,
            iconPath: iconPath,
            legacyProviderID: resolvedLegacyID,
            homeEntry: resolvedHomeEntry,
            runtimeMode: manifest.runtime.mode,
            executableURL: executableURL,
            arguments: Array(manifest.runtime.command.dropFirst()),
            timeout: .milliseconds(clampedTimeoutMs),
            idleTimeout: .seconds(clampedIdleTimeoutSec),
            permissions: Set(manifest.permissions ?? []),
            preferences: manifest.preferences ?? [],
            uiEntryURL: uiEntryURL
        )
    }

    private static func isLowerAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
    }

    private static func normalizeUniqueList(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}

public enum PluginTintParser {
    public static func parse(_ raw: String?) -> IconTint {
        guard let raw else { return .gray }
        return IconTint(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .gray
    }
}
