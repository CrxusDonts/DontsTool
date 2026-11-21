import Foundation

public enum PluginHostError: LocalizedError, Equatable, Sendable {
    case permissionDenied(PluginPermission, pluginID: String)
    case invalidActionTarget(String)
    case missingEffectValue(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let permission, let pluginID):
            "插件 \(pluginID) 未声明「\(permission.displayName)」权限"
        case .invalidActionTarget(let detail):
            "插件动作目标无效：\(detail)"
        case .missingEffectValue(let kind):
            "插件动作 \(kind) 缺少目标参数"
        }
    }
}

@MainActor
public final class PluginHostContext {
    public let settings: SettingsStore
    public let pluginSettings: PluginSettingsStore
    public let usage: UsageStore?
    public let clipboard: (any ClipboardProviding)?
    public let urlOpener: (any URLOpening)?
    public let appLauncher: (any AppLaunching)?
    public let feedback: (any FeedbackProviding)?
    public let prefill: (any QueryPrefilling)?
    public let secrets: (any SecretStoring)?
    public let unavailableKeywords: @MainActor () -> Set<String>
    public let refreshSearch: @MainActor () -> Void
    public let openInTerminal: (@MainActor (URL) async throws -> Void)?
    public let openAI: (@MainActor (QuickAIRequest) -> Void)?
    public let hostVersion: String

    public init(
        settings: SettingsStore,
        pluginSettings: PluginSettingsStore,
        usage: UsageStore? = nil,
        clipboard: (any ClipboardProviding)? = nil,
        urlOpener: (any URLOpening)? = nil,
        appLauncher: (any AppLaunching)? = nil,
        feedback: (any FeedbackProviding)? = nil,
        prefill: (any QueryPrefilling)? = nil,
        secrets: (any SecretStoring)? = nil,
        unavailableKeywords: @escaping @MainActor () -> Set<String> = { [] },
        refreshSearch: @escaping @MainActor () -> Void = {},
        openInTerminal: (@MainActor (URL) async throws -> Void)? = nil,
        hostVersion: String = AppInfo.version,
        openAI: (@MainActor (QuickAIRequest) -> Void)? = nil
    ) {
        self.settings = settings
        self.pluginSettings = pluginSettings
        self.usage = usage
        self.clipboard = clipboard
        self.urlOpener = urlOpener
        self.appLauncher = appLauncher
        self.feedback = feedback
        self.prefill = prefill
        self.secrets = secrets
        self.unavailableKeywords = unavailableKeywords
        self.refreshSearch = refreshSearch
        self.openInTerminal = openInTerminal
        self.hostVersion = hostVersion
        self.openAI = openAI
    }

    public func resolveHostContext() -> [String: String] {
        var context: [String: String] = [
            "hostVersion": hostVersion,
            "aiFormat": settings.aiAPIFormat.rawValue
        ]
        let preferredTerminal = settings.preferredTerminalBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredTerminal.isEmpty {
            context["preferredTerminalBundleID"] = preferredTerminal
        }
        let baseURL = settings.translationAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.translationAPIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            context["aiModel"] = model
        }
        // 只暴露布尔配置状态与非敏感模型名，严禁把任何 API 密钥传入插件上下文。
        let hasAPIKey = !(secrets?.secret(for: SecretAccount.translationAPIKey) ?? "").isEmpty
        context["aiConfigured"] = (!baseURL.isEmpty && !model.isEmpty && hasAPIKey) ? "true" : "false"
        return context
    }

    public func resolvePreferences(for manifest: ResolvedPluginManifest) -> [String: String] {
        var result: [String: String] = [:]
        for spec in manifest.preferences {
            if spec.type == "secret" {
                guard manifest.permissions.contains(.secrets), let secrets else { continue }
                if let value = pluginSettings.secret(forPluginID: manifest.id, key: spec.key, using: secrets) {
                    result[spec.key] = value
                }
            } else if let stored = pluginSettings.preferenceValue(pluginID: manifest.id, key: spec.key) {
                result[spec.key] = stored
            } else if let defaultValue = spec.defaultValue {
                result[spec.key] = defaultValue
            }
        }
        return result
    }

    public func apply(
        effect: PluginActionEffectDTO?,
        toast: String?,
        refresh: Bool?,
        recordUsageKey: String?,
        manifest: ResolvedPluginManifest
    ) async throws {
        if let effect {
            try await executeEffect(effect, manifest: manifest)
        }

        if let toastMessage = toast?.trimmingCharacters(in: .whitespacesAndNewlines), !toastMessage.isEmpty {
            try requirePermission(.toast, for: manifest)
            feedback?.show(toastMessage)
        }

        if let key = recordUsageKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            usage?.recordUse(of: key)
        }

        if refresh == true {
            try requirePermission(.refresh, for: manifest)
            refreshSearch()
        }
    }

    private func executeEffect(_ effect: PluginActionEffectDTO, manifest: ResolvedPluginManifest) async throws {
        switch effect.kind {
        case "none", "":
            break
        case "copy":
            try requirePermission(.clipboardWrite, for: manifest)
            guard let value = effect.value else { throw PluginHostError.missingEffectValue("copy") }
            clipboard?.writeString(value)
        case "openURL":
            try requirePermission(.openURL, for: manifest)
            guard let raw = effect.value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                throw PluginHostError.missingEffectValue("openURL")
            }
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty else {
                throw PluginHostError.invalidActionTarget(raw)
            }
            try urlOpener?.open(url)
        case "openFile":
            try requirePermission(.openFile, for: manifest)
            let url = try resolvedLocalPathURL(effect.value, kind: "openFile")
            try appLauncher?.openFile(at: url)
        case "revealInFinder":
            try requirePermission(.revealInFinder, for: manifest)
            let url = try resolvedLocalPathURL(effect.value, kind: "revealInFinder")
            appLauncher?.revealInFinder(url)
        case "openInTerminal":
            try requirePermission(.openTerminal, for: manifest)
            let url = try resolvedLocalPathURL(effect.value, kind: "openInTerminal")
            try await openInTerminal?(url)
        case "openApplication":
            try requirePermission(.openApplication, for: manifest)
            let url = try resolvedLocalPathURL(effect.value, kind: "openApplication")
            try await appLauncher?.openApplication(at: url)
        case "openAI":
            try requirePermission(.openAI, for: manifest)
            let prompt = effect.value ?? effect.options?["prompt"] ?? ""
            let rawTitle = effect.options?["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (rawTitle?.isEmpty == false) ? rawTitle : nil
            let rawSystem = effect.options?["systemPrompt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let systemPrompt = (rawSystem?.isEmpty == false) ? rawSystem : nil
            let hasPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let autoSend: Bool
            if let rawAutoSend = effect.options?["autoSend"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                if rawAutoSend == "false" || rawAutoSend == "0" {
                    autoSend = false
                } else {
                    autoSend = hasPrompt
                }
            } else {
                autoSend = hasPrompt
            }
            openAI?(QuickAIRequest(
                title: title,
                prompt: prompt,
                systemPrompt: systemPrompt,
                autoSend: autoSend
            ))
        case "prefill":
            try requirePermission(.prefill, for: manifest)
            guard let value = effect.value else { throw PluginHostError.missingEffectValue("prefill") }
            prefill?.prefill(value)
        case "toast":
            try requirePermission(.toast, for: manifest)
            guard let value = effect.value else { throw PluginHostError.missingEffectValue("toast") }
            feedback?.show(value)
        default:
            throw PluginHostError.invalidActionTarget(effect.kind)
        }
    }

    private func resolvedLocalPathURL(_ rawValue: String?, kind: String) throws -> URL {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw PluginHostError.missingEffectValue(kind)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw PluginHostError.invalidActionTarget(raw)
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private func requirePermission(_ permission: PluginPermission, for manifest: ResolvedPluginManifest) throws {
        guard manifest.permissions.contains(permission) else {
            Log.plugin.warning(
                "拦截插件越权动作：\(manifest.id, privacy: .public) 未声明 \(permission.rawValue, privacy: .public)"
            )
            throw PluginHostError.permissionDenied(permission, pluginID: manifest.id)
        }
    }
}
