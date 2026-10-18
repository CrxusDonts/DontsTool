# ADR 0003：翻译采用用户配置的外部 API，而非系统 Translation 框架

- 状态：已接受（2026-10-18）
- 相关：[V1 详细设计 5.5](../superpowers/specs/2026-10-18-dontstool-design.md)、[ADR 0001](0001-native-swift-over-tauri.md)

## 背景

V1 原计划使用 macOS 系统 Translation 框架（`TranslationSession` + SwiftUI `.translationTask`）。实测发现两个不可接受的问题：

1. **首次语言资源下载的确认模态挂在隐形宿主窗口上**。`.translationTask` 需要一个承载视图，启动器为此创建 2×2、alpha 0 的宿主窗口；系统把“下载语言包”的确认 sheet 挂在该窗口上，用户看不到也点不了，翻译会话永久等待，只能靠 30s 超时兜底（日志：`App termination blocked by modal sheet`）。
2. **Swift 6 严格并发下桥接成本高**。`TranslationSession` 非 Sendable，跨 actor 传递需要 `@unchecked Sendable` 包装与状态机防重复 resume，维护负担大。

## 决策

翻译改为调用**用户配置的 OpenAI Responses 兼容 HTTP API**（`POST {baseURL}/responses`，请求 `{model, instructions, input}`，解析 `output_text` 或 `output[].content[].text`）。

- 配置项：接口地址、模型、API 密钥；默认全部留空，未配置时面板显示「配置翻译 API」提示项 + 网页翻译兜底。
- 密钥存登录钥匙串（`KeychainSecretStore`），不落 UserDefaults、不进备份明文。
- 仅在用户显式执行翻译时发送文本；无后台网络、无遥测，符合隐私约束。
- 源语言识别仍用本地 NaturalLanguage，用于“源语言与目标语言相同”的提示。

## 后果

- 正面：无下载门槛、无隐形窗口模态问题、错误信息来自服务端可读文本、可换任意兼容服务商（DeepSeek、OpenAI 等）。
- 负面：需要用户自备密钥；翻译质量与可用性依赖所选服务；文本会离开本机（用户知情配置）。
- 移除代码：`TranslationService.swift`（系统框架桥接）整体删除；`TranslationProvider` 改为基于 `isConfigured` 分支。
