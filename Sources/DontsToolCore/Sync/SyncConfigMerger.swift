import Foundation

/// 提供配置同步的结构化 JSON Diff、按顶层字段勾选合并，以及高版本未知字段透传能力。
public enum SyncConfigMerger: Sendable {
    private static let knownSettingsKeys: Set<String> = [
        "hotKey",
        "applicationSortOrder",
        "enabledProviderIDs",
        "fileSearchEnabled",
        "translationTarget",
        "translationAPIBaseURL",
        "translationAPIModel",
        "selectionHoldDelayRawValue",
        "selectionTranslationEnabled",
        "preferredTerminalBundleID",
        "aiAPIFormat",
        "aiModelProfiles",
        "defaultAIModelProfileID",
        "translationAIModelProfileID",
        "quickAIAIModelProfileID",
        "aiConsumerModelBindings"
    ]

    public static func prettyJSON(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              JSONSerialization.isValidJSONObject(object),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: formatted, as: UTF8.self)
    }

    public static func prettyJSON(from text: String) -> String {
        prettyJSON(from: Data(text.utf8))
    }

    public static func compare(localJSON: String, remoteJSON: String) throws -> JSONComparison {
        try JSONDiff.compare(prettyJSON(from: localJSON), prettyJSON(from: remoteJSON))
    }

    public static func topLevelFieldDiffs(
        entityKey: String,
        localJSON: String,
        remoteJSON: String
    ) -> [SyncConfigFieldDiff] {
        guard let localDict = parseObject(from: localJSON),
              let remoteDict = parseObject(from: remoteJSON) else {
            return []
        }

        let allKeys = Set(localDict.keys).union(remoteDict.keys).sorted()
        var diffs: [SyncConfigFieldDiff] = []

        for key in allKeys {
            let localValue = localDict[key]
            let remoteValue = remoteDict[key]
            if let localValue, let remoteValue, canonicalData(for: localValue) == canonicalData(for: remoteValue) {
                continue
            }

            let kind: JSONDifference.Kind = if localValue == nil {
                .added
            } else if remoteValue == nil {
                .removed
            } else {
                .modified
            }

            diffs.append(
                SyncConfigFieldDiff(
                    key: key,
                    displayName: displayName(for: key, entityKey: entityKey),
                    kind: kind,
                    localPreview: localValue.map { compactPreview(for: $0) } ?? "（未设置）",
                    remotePreview: remoteValue.map { compactPreview(for: $0) } ?? "（未设置）"
                )
            )
        }

        return diffs
    }

    public static func buildMergedJSON(
        localJSON: String,
        remoteJSON: String,
        choices: [String: SyncFieldChoice]
    ) throws -> String {
        guard let localDict = parseObject(from: localJSON),
              let remoteDict = parseObject(from: remoteJSON) else {
            throw CloudSyncError.invalidResponse
        }

        var merged: [String: Any] = [:]
        let allKeys = Set(localDict.keys).union(remoteDict.keys)

        for key in allKeys {
            let localValue = localDict[key]
            let remoteValue = remoteDict[key]

            if let localValue, let remoteValue, canonicalData(for: localValue) == canonicalData(for: remoteValue) {
                merged[key] = localValue
                continue
            }

            switch choices[key] ?? .local {
            case .local:
                if let localValue {
                    merged[key] = localValue
                }
            case .remote:
                if let remoteValue {
                    merged[key] = remoteValue
                }
            }
        }

        let data = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    public static func extractUnknownSettingsFields(from remoteData: Data) -> String? {
        guard let dict = try? JSONSerialization.jsonObject(with: remoteData, options: []) as? [String: Any] else {
            return nil
        }
        let unknown = dict.filter { !knownSettingsKeys.contains($0.key) }
        guard !unknown.isEmpty,
              let data = try? JSONSerialization.data(
                  withJSONObject: unknown,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func injectUnknownSettingsFields(_ unknownJSON: String?, into encodedData: Data) -> Data {
        guard let unknownJSON, !unknownJSON.isEmpty,
              let unknownDict = parseObject(from: unknownJSON),
              var encodedDict = try? JSONSerialization.jsonObject(with: encodedData, options: []) as? [String: Any] else {
            return encodedData
        }

        for (key, value) in unknownDict where encodedDict[key] == nil {
            encodedDict[key] = value
        }

        guard let mergedData = try? JSONSerialization.data(
            withJSONObject: encodedDict,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return encodedData
        }
        return mergedData
    }

    private static func parseObject(from json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8), options: []) as? [String: Any]
    }

    private static func canonicalData(for value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func compactPreview(for value: Any) -> String {
        if let dict = value as? [String: Any] ?? (value as? [Any]).map({ ["_": $0] }) {
            if value is [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]) {
                return String(decoding: data, as: UTF8.self)
            }
            if let array = value as? [Any],
               let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys, .withoutEscapingSlashes]) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        guard let wrapped = canonicalData(for: value) else {
            return String(describing: value)
        }
        let text = String(decoding: wrapped, as: UTF8.self)
        if text.hasPrefix("["), text.hasSuffix("]"), text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func displayName(for key: String, entityKey: String) -> String {
        switch entityKey {
        case SyncEntityKey.settings:
            switch key {
            case "hotKey": "呼出快捷键"
            case "applicationSortOrder": "应用排序方式"
            case "enabledProviderIDs": "启用的搜索来源"
            case "fileSearchEnabled": "文件搜索开关"
            case "translationTarget": "翻译目标语言"
            case "translationAPIBaseURL": "默认接口地址（兼容）"
            case "translationAPIModel": "默认模型名称（兼容）"
            case "aiAPIFormat": "默认接口格式（兼容）"
            case "selectionHoldDelayRawValue": "长按划词触发时长"
            case "selectionTranslationEnabled": "划词翻译开关"
            case "preferredTerminalBundleID": "首选终端应用"
            case "aiModelProfiles": "模型服务列表"
            case "defaultAIModelProfileID": "默认模型配置"
            case "translationAIModelProfileID": "翻译与划词模型（兼容）"
            case "quickAIAIModelProfileID": "AI 快问模型（兼容）"
            case "aiConsumerModelBindings": "各场景模型绑定"
            default: key
            }
        case SyncEntityKey.searchEngines:
            switch key {
            case "version": "配置版本"
            case "defaultEngineID": "默认搜索引擎"
            case "engines": "搜索引擎列表"
            default: key
            }
        case SyncEntityKey.websites:
            switch key {
            case "version": "配置版本"
            case "groups": "网址分组与快捷入口"
            default: key
            }
        default:
            key
        }
    }
}
