# ADR 0008：微内核宿主与进程外 Sidecar 插件架构

- 状态：已实施（微内核精简化 + 官方插件仓 + GitHub 安装器）
- 日期：2026-11-21
- 关联：[ADR 0002](0002-built-in-modules-over-plugin-runtime.md)、[架构总览](../architecture.md)、[插件使用与开发指南](../plugins.md)

## 背景

在 [ADR 0002](0002-built-in-modules-over-plugin-runtime.md) 中，DontsTool 在 V1 阶段有意识地选择了编译期内置 `ToolProvider` 模块，同时为未来演进为进程外 `SidecarProvider` 预留了协议边界。随着内置工具增多以及独立迭代、用户自定义扩展与从 GitHub 安装插件的需求出现，需要将部分功能从主程序解耦为可插拔、可热加载且互不牵连的插件体系。

## 决策

采用 **微内核宿主 + 进程外 Sidecar 插件（NDJSON over stdio）+ GitHub `catalog.json` 插件源** 作为插件化核心架构：

1. **微内核宿主保留边界**
   - **保留宿主**：全局热键与双击修饰键监听、浮动面板与中文 IME 状态机、搜索协调器与注册表、应用索引（FSEvents + 内存拼音匹配）、文本工具窗口（JSON/Base64/URL/时间戳/UUID/Hash）、网页搜索与网址快捷入口、本地便笺（离线 Tiptap WKWebView）、翻译与全局划词翻译、计算器与快速打开微秒级热路径、Gemini 提问、使用指南、Cloudflare 多端同步与备份引擎、钥匙串与系统权限代理、轻量首选终端启动服务（`SystemTerminalFinderService` + `TerminalModels`，供 `QuickOpenProvider` 与 `PluginHostContext.openInTerminal` 复用），以及插件运行时与安装器。
   - **已外迁至官方插件仓库 `CrxusDonts/DontsTool-Plugins` 的 5 个插件**（主仓库已剥离对应内置 Provider、领域服务与临时内嵌 helper）：
     1. `com.donts.kill-process`：结束进程（按名称、PID、命令或 `:端口` 筛选与终止）
     2. `com.donts.idea-projects`：IntelliJ IDEA 最近项目发现与启动
     3. `com.donts.file-search`：Spotlight 文件搜索（`file` 显式触发，返回 `.file` 分组及定位/复制路径动作）
     4. `com.donts.chrome`：Google Chrome 标签页、书签与历史检索及操作
     5. `com.donts.terminal-finder`：访达与 Ghostty / Warp / iTerm2 / 终端双向目录跳转
   - **数据与配置向后兼容**：宿主保留 `ProviderID` 全部历史枚举值、`SettingsStore` 迁移逻辑、`CloudSync` 快照字段与 `FeatureGuideCatalog`，确保升级老用户配置与多端同步数据 100% 兼容。

2. **运行时与通信协议**
   - 所有外部插件通过 `manifest.json`（`schemaVersion == 1`）声明元数据、关键词、`minHostVersion`（语义化版本下限）、运行模式（`oneshot` 或 `daemon`）、声明式首页入口、全局发现别名及所需权限。
   - 宿主与插件通过标准输入/输出的换行分隔 JSON-RPC 2.0（NDJSON over stdio）通信，支持 `search`、`execute`、`cancel`、`shutdown` 消息：
     - `PluginSearchParams` 与 `PluginExecuteParams` 支持 `hostContext`（注入 `hostVersion` 与用户配置的 `preferredTerminalBundleID`）。
     - `PluginSearchItemDTO` 支持可选 `group`（`"tool"` / `"file"` / `"shortcut"` / `"web"`），`PluginActionDTO` 支持可选 `fileAction`（`"reveal"` / `"copyPath"`），使外部文件插件复用启动器原生文件行交互。
     - `PluginHostContext.apply` 为 `async throws`，支持受权限门控的宿主动作：`copy`（`clipboard.write`）、`openURL`、`openFile`、`revealInFinder`、`openInTerminal`（`openTerminal`）、`openApplication`（`openApplication`）、`prefill`、`toast`、`refresh`。
   - 用户安装目录统一为 `~/Library/Application Support/DontsTool/Plugins/<pluginID>/`，同时兼容应用包内 `Contents/Resources/BundledPlugins/` 与 `Contents/Helpers/`（用户目录同 ID 插件优先级更高）。

3. **GitHub `catalog.json` 插件源与两步安全安装流程**
   - **插件源管理（`PluginSourceStore`）**：默认内置官方源 `CrxusDonts/DontsTool-Plugins`（「DontsTool 官方插件仓库」），并持久化用户自定义源（`UserDefaults` key `dontstool.plugins.sources`），支持 `owner/repo`、GitHub 仓库链接或直接 HTTPS `catalog.json` URL。
   - **多级目录拉取（`PluginInstaller`）**：对 GitHub 仓库依次尝试 `releases/latest/download/catalog.json`（绕过 GitHub API 速率限制）→ `raw.githubusercontent.com/<owner>/<repo>/main/catalog.json` → `master/catalog.json` → 单插件仓库回退 `main/manifest.json`，统一用 `PluginCatalogValidator` 校验 `schemaVersion == 1`。
   - **两步安装与权限确认（`inspectPackage` → UI 确认 Sheet → `commitInstall`）**：
     1. 校验 `minHostVersion` 与下载地址（仅限 HTTPS），下载 `.dontsplugin.zip` 或仓库归档；
     2. 使用 `CryptoKit.SHA256` 严格比对 `entry.sha256`；
     3. 通过 `/usr/bin/ditto -x -k` 解压至临时 staging 目录，递归阻断指向目录外的符号链接，补齐 `bin/*` 与入口可执行权限，并通过 `PluginManifestLoader` 校验清单及 `manifest.id == entry.id`；
     4. 对比已安装目录的 `.install-meta.json` 检测跨源同名冲突；
     5. 在设置「插件」页（`PluginsSettingsTabView`）弹出权限确认 Sheet，展示插件名称、版本、来源仓库、关键词、申请权限（`PluginPermission.displayName`）、SHA-256 校验状态以及跨源冲突显式确认开关；
     6. 用户确认后写入 `.install-meta.json`，优雅停用旧实例并原子替换到用户插件目录（失败自动回滚），随后调用 `PluginManager.reload()` 热加载生效；卸载通过 `uninstall(pluginID:)` 校验路径边界、关闭进程、移除目录并热重载。

4. **性能与安全红线**
   - 外部用户插件默认仅响应显式关键词并运行在 `.slow` 阶段，优先级钳制在 `1...50`，超时上限 `2000ms`，防止拖慢 ≤ 50ms 的本地热路径。
   - 不向插件广播剪贴板或全局按键流；插件密钥通过 `plugin.<pluginID>.<key>` 命名空间隔离存储于钥匙串；所有系统动作执行前强制校验 `manifest.permissions`，且 `openURL` 仅接受 `http`/`https`。
   - 退出应用、卸载或重载时同步向活跃插件进程发送终止信号，不遗留孤儿进程。

## 后续演进

- 完善插件签名验证（在 `SHA-256` 基础上引入 `ed25519Signature` 官方公钥验签）。
- 按需抽象离线 `WKWebView` 插件窗口桥（延续 `LocalNoteEditorBridge` 的隔离模式）与插件独立偏好设置表单。
