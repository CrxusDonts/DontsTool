import DontsToolCore
import SwiftUI

struct AIModelsSettingsTabView: View {
    @ObservedObject var settings: SettingsStore
    let secrets: SecretStoring
    let aiService: RemoteAIChatService

    @State private var editorTarget: EditorTarget?
    @State private var pendingDeletion: AIModelProfile?
    @State private var testStates: [String: ConnectionTestState] = [:]
    @State private var secretsRevision = 0

    enum EditorTarget: Identifiable {
        case create
        case edit(AIModelProfile)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let profile): profile.id
            }
        }
    }

    enum ConnectionTestState: Equatable {
        case testing
        case success(TimeInterval)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !settings.aiModelProfiles.isEmpty {
                sceneBindingSection
            }

            profilesSection

            privacyNote
        }
        .sheet(item: $editorTarget) { target in
            AIModelProfileEditorSheet(
                existingProfile: existingProfile(for: target),
                initialAPIKey: initialAPIKey(for: target),
                initiallyDefault: shouldDefaultToDefault(for: target),
                isOnlyProfile: settings.aiModelProfiles.count <= 1 && existingProfile(for: target) != nil,
                aiService: aiService
            ) { savedProfile, apiKey, makeDefault in
                settings.upsertAIModelProfile(savedProfile, makeDefault: makeDefault)
                settings.saveAPIKey(apiKey, for: savedProfile, secrets: secrets)
                testStates.removeValue(forKey: savedProfile.id)
                secretsRevision += 1
            }
        }
        .alert(
            "确认删除模型配置？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { profile in
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
            Button("删除", role: .destructive) {
                settings.deleteAIModelProfile(id: profile.id, secrets: secrets)
                testStates.removeValue(forKey: profile.id)
                secretsRevision += 1
                pendingDeletion = nil
            }
        } message: { profile in
            Text("将删除「\(profile.name)」及其保存在本机钥匙串中的 API 密钥；依赖它的场景将自动回退到默认模型。")
        }
    }

    // MARK: - 分组 1：场景绑定

    private var sceneBindingSection: some View {
        SettingsGroup(caption: "场景绑定") {
            SettingsRow(
                title: "默认模型",
                subtitle: "未单独指定的功能与 AI 插件默认使用"
            ) {
                Picker("默认模型", selection: Binding(
                    get: { resolvedDefaultProfileID },
                    set: { settings.setDefaultAIModelProfileID($0) }
                )) {
                    ForEach(settings.aiModelProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(
                title: "翻译与划词",
                subtitle: "翻译窗口与全局右键长按划词使用的模型"
            ) {
                Picker("翻译与划词", selection: Binding(
                    get: { settings.translationAIModelProfileID ?? "" },
                    set: { settings.setTranslationAIModelProfileID($0.isEmpty ? nil : $0) }
                )) {
                    Text("跟随默认（\(defaultProfileName)）").tag("")
                    ForEach(settings.aiModelProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(
                title: "AI 快问",
                subtitle: "原生 AI 对话窗口与官方「AI 快问」插件使用的模型"
            ) {
                Picker("AI 快问", selection: Binding(
                    get: { settings.quickAIAIModelProfileID ?? "" },
                    set: { settings.setQuickAIAIModelProfileID($0.isEmpty ? nil : $0) }
                )) {
                    Text("跟随默认（\(defaultProfileName)）").tag("")
                    ForEach(settings.aiModelProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
        }
    }

    // MARK: - 分组 2：已配置模型

    private var profilesSection: some View {
        SettingsGroup(caption: "已配置模型") {
            SettingsRow(
                title: settings.aiModelProfiles.isEmpty
                    ? "尚未添加模型服务"
                    : "已配置 \(settings.aiModelProfiles.count) 套模型服务",
                subtitle: "可为翻译、划词与 AI 快问分别绑定不同接口和模型"
            ) {
                Button {
                    editorTarget = .create
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("添加模型")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }

            SettingsDivider()

            if settings.aiModelProfiles.isEmpty {
                emptyProfilesPlaceholder
            } else {
                ForEach(Array(settings.aiModelProfiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { SettingsDivider() }
                    profileRow(profile)
                }
            }
        }
    }

    private var emptyProfilesPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("点击上方「添加模型」即可配置你的大模型服务。")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("支持 OpenAI Responses、Gemini 原生与 OpenAI Chat Completions 三种接口格式，API 密钥仅保存在本机登录钥匙串，不会上传云端或暴露给外部插件。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func profileRow(_ profile: AIModelProfile) -> some View {
        let _ = secretsRevision
        let hasKey = settings.apiKey(for: profile, secrets: secrets) != nil
        let isDefault = resolvedDefaultProfileID == profile.id
        let isTranslationBound = settings.translationAIModelProfileID == profile.id
        let isQuickAIBound = settings.quickAIAIModelProfileID == profile.id
        let testState = testStates[profile.id]
        let isTesting = testState == .testing

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(Theme.settingTitleFont)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)

                    if isDefault {
                        SettingsBadge(text: "默认", tone: .success)
                    }
                    if isTranslationBound {
                        sceneCapsule("翻译")
                    }
                    if isQuickAIBound {
                        sceneCapsule("AI 快问")
                    }
                    if !hasKey {
                        warningCapsule("缺少密钥")
                    }
                }

                Text(subtitle(for: profile))
                    .font(Theme.settingSubtitleFont)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)

                if let testState {
                    testFeedbackView(testState)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                SettingsButton(title: isTesting ? "测试中…" : "测试") {
                    runConnectionTest(for: profile)
                }
                .disabled(isTesting)

                SettingsButton(title: "编辑") {
                    editorTarget = .edit(profile)
                }

                SettingsButton(title: "删除") {
                    pendingDeletion = profile
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sceneCapsule(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Theme.accentFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accentBorder, lineWidth: 0.5))
    }

    private func warningCapsule(_ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5))
            Text(title)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Theme.warning)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Theme.warning.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func testFeedbackView(_ state: ConnectionTestState) -> some View {
        switch state {
        case .testing:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在测试连接…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        case .success(let elapsed):
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                Text(String(format: "连接正常 · %.1fs", elapsed))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.success)
        case .failure(let message):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .foregroundStyle(Color.red)
        }
    }

    private var privacyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
            Text("模型服务 API 密钥仅保存在本机登录钥匙串，不上传云端也不写入本地备份包")
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Helpers

    private var resolvedDefaultProfileID: String {
        if let id = settings.defaultAIModelProfileID,
           settings.aiModelProfiles.contains(where: { $0.id == id }) {
            return id
        }
        return settings.aiModelProfiles.first?.id ?? ""
    }

    private var defaultProfileName: String {
        if let matched = settings.aiModelProfiles.first(where: { $0.id == resolvedDefaultProfileID }) {
            return matched.name
        }
        return "未设置"
    }

    private func subtitle(for profile: AIModelProfile) -> String {
        let base = "\(profile.format.displayName) · \(profile.model)"
        return profile.displayHost.isEmpty ? base : "\(base) · \(profile.displayHost)"
    }

    private func existingProfile(for target: EditorTarget) -> AIModelProfile? {
        switch target {
        case .create: nil
        case .edit(let profile): profile
        }
    }

    private func initialAPIKey(for target: EditorTarget) -> String {
        switch target {
        case .create:
            return ""
        case .edit(let profile):
            return settings.apiKey(for: profile, secrets: secrets) ?? ""
        }
    }

    private func shouldDefaultToDefault(for target: EditorTarget) -> Bool {
        switch target {
        case .create:
            return settings.aiModelProfiles.isEmpty
        case .edit(let profile):
            return resolvedDefaultProfileID == profile.id
        }
    }

    private func runConnectionTest(for profile: AIModelProfile) {
        let key = settings.apiKey(for: profile, secrets: secrets) ?? ""
        testStates[profile.id] = .testing
        Task {
            do {
                let elapsed = try await aiService.testConnection(for: profile, apiKey: key)
                testStates[profile.id] = .success(elapsed)
            } catch {
                testStates[profile.id] = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - 新建 / 编辑模型 Sheet

private struct AIModelProfileEditorSheet: View {
    let existingProfile: AIModelProfile?
    let isOnlyProfile: Bool
    let aiService: RemoteAIChatService
    let onSave: (AIModelProfile, String?, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var format: AIAPIFormat
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey: String
    @State private var makeDefault: Bool
    @State private var testState: AIModelsSettingsTabView.ConnectionTestState?

    init(
        existingProfile: AIModelProfile?,
        initialAPIKey: String,
        initiallyDefault: Bool,
        isOnlyProfile: Bool,
        aiService: RemoteAIChatService,
        onSave: @escaping (AIModelProfile, String?, Bool) -> Void
    ) {
        self.existingProfile = existingProfile
        self.isOnlyProfile = isOnlyProfile
        self.aiService = aiService
        self.onSave = onSave
        _name = State(initialValue: existingProfile?.name ?? "")
        _format = State(initialValue: existingProfile?.format ?? .openAIResponses)
        _baseURL = State(initialValue: existingProfile?.baseURL ?? "")
        _model = State(initialValue: existingProfile?.model ?? "")
        _apiKey = State(initialValue: initialAPIKey)
        _makeDefault = State(initialValue: initiallyDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(existingProfile == nil ? "添加模型配置" : "编辑模型配置")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("支持 OpenAI Responses、Gemini 原生与 OpenAI Chat Completions；密钥保存在本机钥匙串")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Theme.separator.frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsGroup(caption: "基本配置") {
                        SettingsRow(title: "名称", subtitle: "用于区分多套配置，留空自动使用模型名称") {
                            SettingsTextField(placeholder: "例如 DeepSeek / Gemini Flash", text: $name)
                        }
                        SettingsDivider()
                        SettingsRow(title: "接口格式", subtitle: "选择与你的模型服务匹配的 REST 协议") {
                            Picker("接口格式", selection: $format) {
                                ForEach(AIAPIFormat.allCases) { item in
                                    Text(item.displayName).tag(item)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 260)
                        }
                        SettingsDivider()
                        SettingsRow(title: "接口地址", subtitle: baseURLSubtitle) {
                            SettingsTextField(placeholder: format.defaultBaseURLPlaceholder, text: $baseURL)
                        }
                        SettingsDivider()
                        SettingsRow(title: "模型名称", subtitle: "必填，服务方支持的模型标识符") {
                            SettingsTextField(placeholder: format.defaultModelPlaceholder, text: $model)
                        }
                        SettingsDivider()
                        SettingsRow(title: "API 密钥", subtitle: "仅保存在本机登录钥匙串") {
                            SettingsTextField(placeholder: apiKeyPlaceholder, text: $apiKey, isSecure: true)
                        }
                        SettingsDivider()
                        SettingsRow(title: "设为默认模型", subtitle: "作为未单独指定场景的默认回退模型") {
                            Toggle("", isOn: $makeDefault)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(isOnlyProfile && makeDefault)
                        }
                    }

                    if let testState {
                        sheetTestBanner(testState)
                    }
                }
                .padding(20)
            }

            Theme.separator.frame(height: 0.5)

            HStack(spacing: 10) {
                SettingsButton(title: testState == .testing ? "测试中…" : "测试连接") {
                    runDraftConnectionTest()
                }
                .disabled(testState == .testing || !canTest)

                Spacer()

                SettingsButton(title: "取消") {
                    dismiss()
                }

                Button {
                    saveAndDismiss()
                } label: {
                    Text("保存")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5.5)
                        .background(
                            canSave ? Theme.accent : Theme.accent.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.footerBase)
        }
        .frame(width: 560, height: 470)
        .background(Theme.panelSolid)
        .onChange(of: format) { _, _ in testState = nil }
        .onChange(of: baseURL) { _, _ in testState = nil }
        .onChange(of: model) { _, _ in testState = nil }
        .onChange(of: apiKey) { _, _ in testState = nil }
    }

    private var baseURLSubtitle: String {
        switch format {
        case .openAIResponses:
            "必填，自动补全 /responses 路径，使用 Bearer 请求头鉴权"
        case .gemini:
            "必填，自动补全 /v1beta；使用 x-goog-api-key 请求头鉴权，密钥不写入 URL"
        case .openAIChatCompletions:
            "必填，自动补全 /chat/completions 路径，使用 Bearer 请求头鉴权"
        }
    }

    private var apiKeyPlaceholder: String {
        switch format {
        case .gemini: "AIza…"
        case .openAIResponses, .openAIChatCompletions: "sk-…"
        }
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedBaseURL.isEmpty && !trimmedModel.isEmpty
    }

    private var canTest: Bool {
        canSave && !trimmedAPIKey.isEmpty
    }

    private func buildDraftProfile() -> AIModelProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? trimmedModel : trimmedName
        return AIModelProfile(
            id: existingProfile?.id ?? UUID().uuidString,
            name: resolvedName,
            format: format,
            baseURL: trimmedBaseURL,
            model: trimmedModel
        )
    }

    private func runDraftConnectionTest() {
        let draft = buildDraftProfile()
        let key = trimmedAPIKey
        testState = .testing
        Task {
            do {
                let elapsed = try await aiService.testConnection(for: draft, apiKey: key)
                testState = .success(elapsed)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private func saveAndDismiss() {
        let profile = buildDraftProfile()
        let keyToStore = trimmedAPIKey.isEmpty ? nil : trimmedAPIKey
        onSave(profile, keyToStore, makeDefault)
        dismiss()
    }

    @ViewBuilder
    private func sheetTestBanner(_ state: AIModelsSettingsTabView.ConnectionTestState) -> some View {
        switch state {
        case .testing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在向模型服务发送连通性测试请求…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
        case .success(let elapsed):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text(String(format: "连接测试通过，响应耗时 %.1fs", elapsed))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.success)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.success.opacity(0.28), lineWidth: 0.6)
            )
        case .failure(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red)
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.red.opacity(0.24), lineWidth: 0.6)
            )
        }
    }
}
