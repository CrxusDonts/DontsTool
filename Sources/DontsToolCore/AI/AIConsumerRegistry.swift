import Combine
import Foundation

/// 响应式 AI 模型消费方注册表：
/// 宿主内置功能与外部 Sidecar 插件声明 AI 能力后在此动态注册，供「设置 → 模型服务 → 场景绑定」按需展示。
@MainActor
public final class AIConsumerRegistry: ObservableObject {
    @Published public private(set) var consumers: [AIConsumerDescriptor] = []

    private var orderedSourceIDs: [String] = []
    private var descriptorsBySourceID: [String: [AIConsumerDescriptor]] = [:]
    private var cancellablesBySourceID: [String: AnyCancellable] = [:]

    public init() {}

    public func setConsumers(_ descriptors: [AIConsumerDescriptor], forSource sourceID: String) {
        if !orderedSourceIDs.contains(sourceID) {
            orderedSourceIDs.append(sourceID)
        }
        descriptorsBySourceID[sourceID] = descriptors
        rebuild()
    }

    public func unregisterSource(_ sourceID: String) {
        cancellablesBySourceID.removeValue(forKey: sourceID)?.cancel()
        descriptorsBySourceID.removeValue(forKey: sourceID)
        orderedSourceIDs.removeAll { $0 == sourceID }
        rebuild()
    }

    public func registerSource<P: Publisher>(
        id sourceID: String,
        publisher: P
    ) where P.Output == [AIConsumerDescriptor], P.Failure == Never {
        cancellablesBySourceID.removeValue(forKey: sourceID)?.cancel()
        if !orderedSourceIDs.contains(sourceID) {
            orderedSourceIDs.append(sourceID)
        }
        cancellablesBySourceID[sourceID] = publisher.sink { [weak self] descriptors in
            self?.setConsumers(descriptors, forSource: sourceID)
        }
    }

    private func rebuild() {
        var seen: Set<String> = []
        var merged: [AIConsumerDescriptor] = []
        for sourceID in orderedSourceIDs {
            guard let list = descriptorsBySourceID[sourceID] else { continue }
            for descriptor in list where seen.insert(descriptor.id).inserted {
                merged.append(descriptor)
            }
        }
        if merged != consumers {
            consumers = merged
        }
    }
}

public extension AIConsumerRegistry {
    /// 内置「翻译与划词」消费方：仅当启用翻译工具或划词翻译时注册，关闭时隐藏（保留绑定记录）。
    func registerBuiltInTranslationConsumer(settings: SettingsStore) {
        let publisher = Publishers.CombineLatest(
            settings.$enabledProviderIDs,
            settings.$selectionTranslationEnabled
        )
        .map { enabledProviderIDs, selectionEnabled -> [AIConsumerDescriptor] in
            let translationEnabled = enabledProviderIDs.contains(ProviderID.translation.rawValue)
            guard translationEnabled || selectionEnabled else {
                return []
            }
            return [
                AIConsumerDescriptor(
                    id: AIConsumerID.translation,
                    title: "翻译与划词",
                    subtitle: "内置 · 翻译窗口与全局右键长按划词使用的模型",
                    source: .builtIn,
                    badgeTitle: "翻译"
                )
            ]
        }
        registerSource(id: "builtin.translation", publisher: publisher)
    }

    /// 外部 Sidecar 插件消费方：只要插件已加载、启用且声明了 `openAI` 权限即自动注册。
    func registerPluginConsumers(
        pluginManager: PluginManager,
        pluginSettings: PluginSettingsStore,
        settings: SettingsStore
    ) {
        let publisher = Publishers.CombineLatest3(
            pluginManager.$records,
            pluginSettings.$disabledPluginIDs,
            settings.$enabledProviderIDs
        )
        .map { records, disabledPluginIDs, enabledProviderIDs -> [AIConsumerDescriptor] in
            records.compactMap { record in
                guard record.status == .loaded,
                      record.permissions.contains(.openAI) else {
                    return nil
                }
                let isEnabled: Bool
                if record.origin == .bundled, let legacyID = record.legacyProviderID {
                    isEnabled = enabledProviderIDs.contains(legacyID)
                } else {
                    isEnabled = !disabledPluginIDs.contains(record.id)
                }
                guard isEnabled else { return nil }

                let trimmedDesc = record.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let subtitle = trimmedDesc.isEmpty
                    ? "插件（\(record.id)）使用的模型"
                    : "插件 · \(trimmedDesc)"
                return AIConsumerDescriptor(
                    id: AIConsumerID.plugin(record.id),
                    title: record.name,
                    subtitle: subtitle,
                    source: .plugin(id: record.id),
                    badgeTitle: record.name
                )
            }
        }
        registerSource(id: "plugins.openAI", publisher: publisher)
    }
}
