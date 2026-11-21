# DontsTool 仓库协作指南

本文件适用于整个仓库。用中文沟通和编写项目说明，代码标识符沿用现有英文命名。开始修改前查看 `git status --short`，保留其他任务留下的改动。

## 项目与入口

DontsTool 是原生 macOS 菜单栏效率启动器，采用微内核宿主 + 进程外 Sidecar 插件架构，使用 Swift 6、AppKit 和 SwiftUI，最低支持 macOS 26。开发使用 Xcode、XcodeGen 和 Make。工程配置以 `project.yml` 为源，`DontsTool.xcodeproj` 由 XcodeGen 生成。

| 路径 | 职责 |
| --- | --- |
| `Sources/DontsTool/App/` | 应用生命周期、菜单栏与依赖组装。微内核内置 Provider、`PluginManager`、`PluginSourceStore` 与 `PluginInstaller` 在 `AppController` 中组装。 |
| `Sources/DontsTool/Shell/` | AppKit 窗口、热键、输入法、焦点、系统事件和 WebKit 桥接。 |
| `Sources/DontsTool/UI/` | SwiftUI 界面（含「插件」设置页 `PluginsSettingsTabView`）。优先复用 `DesignSystem/` 中的颜色、间距和动效定义。 |
| `Sources/DontsToolCore/` | 查询解析、搜索协调、微内核内置 Provider、工具逻辑、便笺、云同步、终端启动服务（`Terminal/`）以及 Sidecar 插件运行时与安装器（`Plugins/`）。 |
| `Tests/DontsToolCoreTests/`、`Tests/DontsToolBridgeTests/` | 分别覆盖核心逻辑（含插件运行时/源管理/安装器）和原生界面、系统事件及 WebKit 集成。 |
| `Web/NotesEditor/`、`Resources/NotesEditor/` | 分别存放离线便笺编辑器源码和随应用分发的构建产物。 |
| `scripts/`、`.github/workflows/` | 安装、打包、更新签名与 CI 发布流程。 |

## 修改约定

- 沿用微内核宿主与外部插件的职责边界：高频热路径、独立工具窗口、离线便笺、划词监听壳、云同步与插件运行时留在主仓库；一般外部集成与命令类扩展优先以 Sidecar 插件形式开发（官方插件仓库位于 [CrxusDonts/DontsTool-Plugins](https://github.com/CrxusDonts/DontsTool-Plugins)，已承接 `kill-process`、`idea-projects`、`file-search`、`chrome`、`terminal-finder`）。
- 调整 `Sources/DontsToolCore/Plugins/` 中的协议或清单契约（`PluginProtocol.swift`、`PluginManifest.swift`、`PluginCatalog.swift`）时，需同步核对 `CrxusDonts/DontsTool-Plugins` 侧实现与 [插件使用与开发指南](docs/plugins.md)，确保向后兼容。
- 启动器以键盘操作为主。改动搜索或面板时，检查焦点恢复、中文输入法组词、键盘动作、旧查询取消以及慢速阶段（含外部插件）超时隔离，保持快速阶段本地响应。
- 修改设置、网址或便笺存储时，验证已有数据仍能读取，保留历史 `ProviderID` 枚举值与 `SettingsStore` / `CloudSync` 迁移兼容。改动便笺编辑器应修改 `Web/NotesEditor/` 源码，并同步更新 `Resources/NotesEditor/` 构建产物；修改桥接消息时同时核对原生和 Web 两端。
- 剪贴板访问沿用用户触发的入口。翻译服务密钥、云同步密钥和插件密钥存放在钥匙串，更新签名私钥和生产数据不得写入源码、测试夹具或日志。

## 构建与验证

| 命令 | 用途 |
| --- | --- |
| `make build` | 生成工程并构建 Debug 应用。可用 `open build/Build/Products/Debug/DontsTool.app` 打开。 |
| `make test` | 运行 Core 测试（含插件运行时、插件源与安装器单测）。 |
| `make test-bridge` | 运行原生界面和 WebKit 桥接测试。 |
| `make test-editor` | 安装锁定的 Node.js 依赖、测试并重新生成便笺编辑器资源。 |
| `make test-updater` | 解析 Xcode 包依赖并验证签名更新源相关脚本。 |
| `make test-installer` | 运行安装脚本测试。 |

按改动范围选择验证命令。热键、焦点、中文输入法、插件权限弹窗或系统授权等行为需要在本机应用里确认，报告时注明实际覆盖范围。`make run` 会先结束正在运行的 DontsTool，使用前留意已打开的草稿。

架构与技术决策见 [架构总览](docs/architecture.md)、[插件指南](docs/plugins.md) 和 [ADR](docs/adr/)，CI 以 [工作流定义](.github/workflows/ci.yml) 为准。打包、签名与发布见 [发布文档](docs/releasing.md)，版本号以 `Resources/Info.plist` 的 `CFBundleShortVersionString` 为准。
