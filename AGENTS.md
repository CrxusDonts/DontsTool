# DontsTool 仓库协作指南

本文件适用于整个仓库。用中文沟通和编写项目说明，代码标识符沿用现有英文命名。开始修改前查看 `git status --short`，保留其他任务留下的改动。

## 项目与入口

DontsTool 是原生 macOS 菜单栏效率工具，使用 Swift 6、AppKit 和 SwiftUI，最低支持 macOS 26。开发使用 Xcode、XcodeGen 和 Make。工程配置以 `project.yml` 为源，`DontsTool.xcodeproj` 由 XcodeGen 生成。

| 路径 | 职责 |
| --- | --- |
| `Sources/DontsTool/App/` | 应用生命周期、菜单栏和依赖组装。Provider 在 `AppController` 中传入 `ToolRegistry`。 |
| `Sources/DontsTool/Shell/` | AppKit 窗口、热键、输入法、焦点、系统事件和 WebKit 桥接。 |
| `Sources/DontsTool/UI/` | SwiftUI 界面。优先复用 `DesignSystem/` 中的颜色、间距和动效定义。 |
| `Sources/DontsToolCore/` | 查询解析、搜索协调、Provider、工具逻辑、存储和系统服务。 |
| `Tests/DontsToolCoreTests/`、`Tests/DontsToolBridgeTests/` | 分别覆盖核心逻辑和原生界面、系统事件及 WebKit 集成。 |
| `Web/NotesEditor/`、`Resources/NotesEditor/` | 分别存放离线便笺编辑器源码和随应用分发的构建产物。 |
| `scripts/`、`.github/workflows/` | 安装、打包、更新签名与 CI 发布流程。 |

## 修改约定

- 沿用 Core、原生窗口与 SwiftUI 界面的职责边界。新增搜索能力优先扩展 `ToolProvider`，查询路由和结果排序沿用现有协调逻辑。
- 启动器以键盘操作为主。改动搜索或面板时，检查焦点恢复、中文输入法组词、键盘动作及旧查询取消。Spotlight 文件搜索由 `file 关键词` 显式触发，普通查询保持快速响应。
- 修改设置、网址或便笺存储时，验证已有数据仍能读取。改动便笺编辑器应修改 `Web/NotesEditor/` 源码，并同步更新 `Resources/NotesEditor/` 构建产物。修改桥接消息时同时核对原生和 Web 两端。
- 剪贴板访问沿用用户触发的入口。翻译服务密钥存放在钥匙串，更新签名私钥和生产数据不得写入源码、测试夹具或日志。

## 构建与验证

| 命令 | 用途 |
| --- | --- |
| `make build` | 生成工程并构建 Debug 应用。可用 `open build/Build/Products/Debug/DontsTool.app` 打开。 |
| `make test` | 运行 Core 测试。 |
| `make test-bridge` | 运行原生界面和 WebKit 桥接测试。 |
| `make test-editor` | 安装锁定的 Node.js 依赖、测试并重新生成便笺编辑器资源。 |
| `make test-updater` | 解析 Xcode 包依赖并验证签名更新源相关脚本。 |
| `make test-installer` | 运行安装脚本测试。 |

按改动范围选择验证命令。热键、焦点、中文输入法或系统权限等行为需要在本机应用里确认，报告时注明实际覆盖范围。`make run` 会先结束正在运行的 DontsTool，使用前留意已打开的草稿。

架构与技术决策见 [架构总览](docs/architecture.md) 和 [ADR](docs/adr/)，CI 以 [工作流定义](.github/workflows/ci.yml) 为准。打包、签名与发布见 [发布文档](docs/releasing.md)，版本号以 `Resources/Info.plist` 的 `CFBundleShortVersionString` 为准。
