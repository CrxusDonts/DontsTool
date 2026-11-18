# DontsTool 架构总览

> 状态：当前实现（V1 + 启动器扩展）。最后更新：2026-11-17。
> 详细行为与验收标准见 [V1 详细设计](superpowers/specs/2026-10-18-dontstool-design.md)。

## 1. 项目定位

DontsTool 是一个个人自用的原生 macOS 效率启动器。按下全局热键呼出浮动面板，输入即搜：

- 启动应用、打开文件
- 用关键词打开文本工具的独立具名工作窗口（JSON、Base64、URL、时间戳、UUID、Hash）；每次明确执行均新建会话
- 网页搜索
- 翻译

设计目标：

1. **原生响应**：启动器和工具使用原生窗口，本地便笺按需使用离线 WKWebView，不引入 Electron/Tauri；热键到面板可见目标 < 100ms。
2. **键盘优先**：高频操作全部可以用键盘完成。
3. **易扩展**：新增工具只需实现 `ToolProvider` 并注册，不改搜索核心。
4. **可维护**：模块边界清晰，决策有 ADR，行为有验收标准。
5. **隐私优先**：无遥测；不监听剪贴板；网络仅由用户主动执行网页搜索、翻译或检查应用更新时触发。

V1 非目标：跨平台、第三方插件市场、启动器自身账号与云同步、App Store 发布与沙盒。

## 2. 技术栈

| 项目 | 选择 |
| --- | --- |
| 语言 | Swift 6 |
| UI | SwiftUI 承载全部界面内容（面板、设置、Toast），AppKit 只做薄壳（NSPanel、热键、搜索框键盘/IME、菜单栏）；设计令牌层 `UI/DesignSystem` |
| 全局热键 | Carbon `RegisterEventHotKey` |
| 应用启动 | `NSWorkspace` |
| 文件搜索 | Spotlight（`mdfind`） |
| 翻译 | 用户配置的 OpenAI Responses 兼容 HTTP API（`URLSession`）；密钥存钥匙串 |
| 开机启动 | `SMAppService` |
| Hash | `CryptoKit` |
| 持久化 | `UserDefaults`（设置）、钥匙串（翻译 API 密钥）、应用支持目录内的版本化 JSON 与便笺附件 |
| 构建 | XcodeGen 生成工程 + `xcodebuild`，Makefile 封装；Xcode 27 / Swift 6.4 |
| 第三方依赖 | 本地便笺离线打包 Tiptap 3.34.0 / ProseMirror；构建依赖 XcodeGen、编辑器生成依赖 Node / esbuild |
| 分发 | GitHub Release（Universal），Developer ID（`Q2K3CAKGG2`）签名与 Apple 公证，非沙盒 |

## 3. 进程与运行形态

- 单进程 App，菜单栏常驻。
- `LSUIElement = true`，激活策略 `.accessory`，不显示 Dock 图标。
- 启动时注册全局热键，并在后台构建应用索引；面板随时可呼出。
- 空闲时没有轮询和定时任务，只等待热键与用户输入。
- 退出入口在菜单栏菜单中。
- 非沙盒运行，方便文件搜索与系统集成；不以 App Store 发布为目标。

## 4. 模块划分

```mermaid
flowchart TD
    HK[HotKeyManager / ModifierDoubleTapMonitor] --> Panel[LauncherPanelController]
    Panel --> Field[SearchField]
    Field --> Coord[SearchCoordinator]
    Coord --> Registry[ToolRegistry]
    Registry --> AppP[AppProvider]
    Registry --> FileP[FileProvider]
    Registry --> TextP[TextToolsProvider]
    Registry --> WebP[WebSearchProvider]
    Registry --> TransP[TranslationProvider]
    Registry --> CalcP[CalculatorProvider]
    Registry --> QuickP[QuickOpenProvider]
    Registry --> SiteP[WebsiteShortcutProvider]
    Registry --> NoteP[NotesProvider]
    NoteP --> Notes[LocalNoteWindowManager / LocalNoteSession]
    Notes --> NoteStore[LocalNoteStore / note.json / assets]
    Notes --> NoteWeb[本地 Tiptap / WKWebView]
    AppP --> Index[AppIndex]
    FileP --> Spotlight[mdfind / Spotlight]
    TransP --> RemoteAPI[Responses API]
    CalcP --> Calc[CalculatorEngine]
    QuickP --> QParser[QuickOpenParser]
    Coord --> List[LauncherPanelModel / LauncherPanelView]
    List -->|Enter / ⌘K| Action[ItemAction]
    Action --> System[NSWorkspace / NSPasteboard / Browser]
```

| 模块 | 职责 | 关键类型 |
| --- | --- | --- |
| AppShell | 应用生命周期、菜单栏、浮动面板、热键、焦点管理、独立工具与便笺窗口 | `AppDelegate`、`HotKeyManager`、`ModifierDoubleTapMonitor`、`LauncherPanelController`、`MenuBarController` |
| Core | 查询解析、路由、聚合、排序、注册、设置与使用统计、即时计算与路径识别 | `SearchCoordinator`、`QueryParser`、`ToolRegistry`、`FuzzyMatcher`、`UsageStore`、`SettingsStore`、`CalculatorEngine`、`QuickOpenParser` |
| Index | 应用索引与文件搜索 | `AppIndex`、`FileSearchService` |
| Providers | 各类结果提供者，统一实现 `ToolProvider` | `AppProvider`、`FileProvider`、`TextToolsProvider`、`WebSearchProvider`、`TranslationProvider`、`CalculatorProvider`、`QuickOpenProvider`、`WebsiteShortcutProvider`、`NotesProvider` |
| Tools | 独立工具窗口与文本处理 | `ToolDefinition`、`ToolSession`、`ToolWindowManager`、`JSONDocument` |
| Notes | 本地便笺、离线富文本、自动保存与独立附件 | `LocalNoteStore`、`LocalNoteSession`、`LocalNoteEditorBridge`、`LocalNoteWindowManager` |
| Sync | Cloudflare 多端增量同步与本地快照备份 | `CloudSyncCoordinator`、`CloudSyncClient`、`SyncStateStore`、`BackupArchiveService` |
| Services | 外部 API、钥匙串、登录项、系统动作 | `RemoteTranslationService`、`SecretStore`、`LoginItemManager`、`SystemAppLauncher` |
| Settings | 设置界面、网址配置、热键录制 | `SettingsWindowController`、`SettingsRootView` |

## 5. 关键流程

### 5.1 呼出与隐藏

1. 用户按下全局热键，`HotKeyManager` 收到 Carbon 事件。
2. 记录当前前台应用，供隐藏时恢复焦点。
3. 面板定位到鼠标所在屏幕顶部偏中位置。
4. `makeKeyAndOrderFront`，搜索框成为第一响应者。
5. 再次按热键、按 `Esc`、面板失焦、或执行完动作后隐藏。
6. 隐藏后如抢走了前台焦点，则激活之前记录的应用。

窗口进入与退出由 `PanelTransitionDriver` 管理位置和透明度，转场期间使用窗口所属显示器的 `CADisplayLink` 驱动，完成或取消即释放。支持中途反向与取消，避免旧的关闭回调隐藏重新打开的面板。SwiftUI 用行锚点定位一块连续滑动的选中背景，并管理操作浮层；动效跟随系统「减少动态效果」，背景跟随「减少透明度」。

### 5.2 搜索

1. 搜索框已确认文本变化，`QueryParser` 判断是全局模式还是关键词模式。AppKit marked text 组合期间暂停搜索并取消旧查询，清除旧的可执行结果；候选词方向键、回车和 Esc 归输入法处理。`LauncherFieldEditor` 同时覆盖 unmarkText 与 insertText 的提交路径，在最外层编辑完成后恢复查询，避免提交中间态。
2. **快速阶段**：应用、文本工具提示、网页搜索、算式/单位换算、网址/路径识别在每次输入时立即参与，结果立即渲染。
3. **慢速阶段**：仅 `file 关键词` 路由到文件搜索，已确认输入停止 120ms 后触发，查询上限 2 秒，正常完成立即返回。`ToolProvider.supportsGlobalSearch` 默认 true，文件 Provider 为 false；普通查询完全跳过文件 Provider 和慢速等待。`file` 无参数不创建查询进程，完整路径由 QuickOpen 处理。
4. 新的输入或输入法组词开始时取消上一轮慢速请求；过期结果直接丢弃，取消不报告文件服务失败。查询超时或取消时先发送终止信号，200ms 后仍未退出的进程强制结束。
5. 结果按分组和分数排序、去重后展示。算式和快速打开的分数高于普通工具提示；存在本地结果时不再展示网页回退。

应用的 `AppSearchDocument` 缓存中文拼音、首字母和文件名别名，索引变化时更新，避免逐次输入做音译。扫描器每次直接读取原始 plist 和本地化 strings／loctable，避免同路径安装或更新后读到缓存名称。空查询默认只展示从启动器成功打开过的应用，按最近打开时间倒序，最多四个，不用未打开的应用填充。只有应用结果的打开动作成功后才写入时间和次数，不再订阅系统应用激活通知。频率和名称排序仍可浏览其他索引应用；主动输入搜索不受历史范围限制。旧应用历史一次性移除零次数系统激活项，保留真实打开次数并重置不可信时间；未知时间的旧项目不参与最近列表，下次从启动器打开后重新进入。网址和文件历史不变。排序偏好和使用记录保存在本机。

空输入框的显式粘贴进入独立的内容操作流程：`ContentDescriptor` 识别类型，`ContentActionProvider` 生成工具入口，`LauncherPanelModel` 取消全局查询并保留原文。筛选只作用于动作，源文本不传给全局 Provider；移除内容或关闭面板时清理。打开工具仅预填原文，转换和网络请求由用户在工具窗口内执行。

### 5.3 执行

1. 用户按 `Enter` 或点击结果项，执行该项的主操作。文件行在选中或悬停时显示独立文件夹按钮，按该行索引执行第二动作，在访达中选中文件；主按钮与文件夹按钮并列，避免点击定位时同时打开文件。
2. 按 `⌘K` 打开当前结果的动作面板，`↑`、`↓` 选择，`Enter` 执行全部操作中的任意一项；`⌘Enter` 仍执行次操作。
3. 打开类动作记录一次使用（用于排序加权）；仅复制动作在用户明确执行时写入剪贴板。
4. 关闭面板。
5. 具体动作由 Provider 提供：启动应用、打开文件、退出应用、在 Finder 中显示、复制路径/链接、打开浏览器。

## 6. 扩展模型

所有工具实现同一个协议（详见详细设计第 3 节）：

```swift
@MainActor
protocol ToolProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var keywords: [String] { get }
    var priority: Int { get }
    var isEnabled: Bool { get set }
    var phase: SearchPhase { get }        // 默认 .fast；文件搜索为 .slow
    var statusNotice: String? { get }     // 最近一次搜索的降级说明

    func search(_ context: SearchContext) async -> [SearchItem]
}
```

新增一个工具的步骤：

1. 新建 `XxxProvider.swift`，实现 `ToolProvider`。
2. 在 `ToolRegistry.bootstrap()` 中注册。
3. 为它补充单元测试。
4. 如引入新的交互模式，更新详细设计文档。

V1 没有运行时插件加载、插件市场或进程隔离。增加工具需要重新编译 App；这是有意的取舍，原因见 [ADR 0002](adr/0002-built-in-modules-over-plugin-runtime.md)。

## 7. 性能设计

| 指标 | 预算 |
| --- | --- |
| 热键到面板可见 | ≤ 100ms（p95，应用已驻留） |
| 输入到本地结果出现 | ≤ 50ms（p95） |
| 文件结果出现 | 常规目标 ≤ 300ms（p95）；慢查询硬上限 2 秒，超时保留部分结果 |
| 常驻内存 | ≤ 150MB |
| 空闲 CPU | ≤ 0.5% |
| 冷启动到可呼出 | ≤ 1.5s |

手段：

- 应用索引常驻内存，启动时后台扫描；通过 FSEvents 监听应用目录及包内变更，合并 350ms 内的事件后在后台重扫，完成后刷新启动器结果。扫描中到达的刷新请求会补扫；退出时释放监听，不做空闲轮询。尚未创建的用户应用目录通过祖先目录事件捕获，非目标路径不触发刷新。
- 应用元数据直接读取当前 `Contents/Info.plist`，避免 `Bundle.infoDictionary` 的进程缓存导致分阶段安装或原路径更新后仍保留旧内容。图标懒加载并缓存。
- 快速/慢速两阶段搜索，慢速请求可取消。
- 限制每类结果数量，避免大列表布局开销。
- 热路径上不做磁盘 I/O；使用统计延迟批量写入。
- 原生启动器不加载 WebView；本地便笺在主动调用时按需加载系统离线 WKWebView。

## 8. 权限、隐私与安全

- **全局热键**：组合键用 Carbon 注册，不需要辅助功能（Accessibility）权限；双击修饰键仅订阅 `NSEvent.flagsChanged`，用系统按键计数与最近按键时间打断组合输入，不订阅全局普通按键，不申请输入监控或辅助功能权限。当前系统的独立 App 已在两项权限均关闭时收到跨应用修饰键事件，见 ADR 0005。
- **文件搜索**：依赖 Spotlight 索引；部分目录可能需要“完全磁盘访问权限”，没有授权时返回部分结果，不影响其他功能。
- **翻译**：用户主动执行翻译时，把文本发送到其配置的 OpenAI Responses 兼容接口；API 密钥存登录钥匙串，不写 UserDefaults，不做额外上报。
- **开机启动**：通过 `SMAppService` 注册登录项。
- **网络**：应用在用户主动执行网页搜索（交给默认浏览器）、翻译、检查更新，或开启 Cloudflare 多端同步后与自建同步服务通信时联网。
- **剪贴板**：不监听；启动器搜索不读剪贴板。在工具窗口中显式粘贴或复制、动作面板复制，以及长按划词翻译时访问；划词翻译只读取本次复制后的内容，不清空或还原剪贴板。
- **键盘**：仅在启用双击修饰键时订阅全局和本地修饰键变化；第二次短按松开后触发。只查询普通按键的计数和最近事件时间，不接收或记录按键内容；无轮询。
- **进程调用**：仅以固定可执行文件 `/usr/bin/mdfind` 加参数数组的方式调用，不经过 shell。
- **签名**：正式发布使用 Developer ID（`Q2K3CAKGG2`）签名、开启 Hardened Runtime 并经 Apple 公证，非沙盒（本地日常开发与测试构建使用 ad-hoc 签名，无需证书）；不引入第三方二进制。双击监听不依赖输入监控授权。

## 9. 目录结构

```text
DontsTool/
├── project.yml                    # XcodeGen 工程定义（源）
├── DontsTool.xcodeproj/           # 生成物，不手改
├── Makefile
├── Resources/
│   └── Info.plist
├── Sources/
│   ├── DontsTool/                 # App target：生命周期与全部 UI
│   │   ├── DontsToolMain.swift
│   │   ├── App/
│   │   │   ├── AppDelegate.swift
│   │   │   ├── AppController.swift
│   │   │   └── MenuBarController.swift
│   │   ├── Shell/
│   │   │   ├── HotKeyManager.swift          # Carbon 组合键
│   │   │   ├── ModifierDoubleTapMonitor.swift # 只读双击监听
│   │   │   ├── LauncherPanel.swift
│   │   │   ├── LauncherPanelController.swift
│   │   │   ├── SearchField.swift
│   │   │   ├── SettingsWindowController.swift
│   │   │   ├── OnboardingWindowController.swift
│   │   │   └── ToastPresenter.swift
│   │   ├── UI/
│   │   │   ├── DesignSystem/          # Theme / Metrics / Motion 令牌
│   │   │   ├── Components/            # 行、图标块、键帽、底栏、Toast
│   │   │   ├── Launcher/              # LauncherPanelView
│   │   │   └── Settings/              # SettingsRootView、组件、热键录制、引导
│   └── DontsToolCore/             # 静态库 target：可独立测试的逻辑
│       ├── Core/
│       │   ├── Models.swift
│       │   ├── LauncherPanelModel.swift
│       │   ├── ModifierDoubleTapDetector.swift
│       │   ├── HotKeyFormatter.swift
│       │   ├── LanguageIdentification.swift
│       │   ├── SearchCoordinator.swift
│       │   ├── QueryParser.swift
│       │   ├── ToolRegistry.swift
│       │   ├── FuzzyMatcher.swift
│       │   ├── UsageStore.swift
│       │   ├── SettingsStore.swift
│       │   ├── Protocols.swift
│       │   ├── PathDisplay.swift
│       │   ├── Performance.swift
│       │   ├── Logging.swift
│       │   ├── CalculatorEngine.swift
│       │   ├── QuickOpenParser.swift
│       │   └── AppInfo.swift
│       ├── Index/
│       │   ├── AppScanner.swift
│       │   ├── AppIndex.swift
│       │   └── FileSearchService.swift
│       ├── Providers/
│       │   ├── AppProvider.swift
│       │   ├── FileProvider.swift
│       │   ├── TextToolsProvider.swift
│       │   ├── TextTransformers.swift
│       │   ├── WebSearchProvider.swift
│       │   ├── TranslationProvider.swift
│       │   ├── CalculatorProvider.swift
│       │   ├── QuickOpenProvider.swift
│       │   ├── WebsiteShortcutProvider.swift
│       │   └── NotesProvider.swift
│       ├── Sync/
│       │   ├── SyncModels.swift
│       │   ├── CloudSyncClient.swift
│       │   ├── BackupArchiveService.swift
│       │   ├── CloudSyncCoordinator.swift
│       │   ├── CloudSyncSnapshotBuilder.swift
│       │   └── CloudSyncRemoteApplier.swift
│       └── Services/
│           ├── SystemServices.swift
│           ├── RemoteTranslationService.swift
│           ├── HTTPClient.swift
│           ├── SecretStore.swift
│           └── LoginItemManager.swift
├── Tests/
│   └── DontsToolCoreTests/
├── build/                         # 构建产物，不提交
└── docs/
```

## 10. 测试策略

- **单元测试**（Swift Testing）：模糊匹配、查询解析、排序、文本转换、URL 构造、索引过滤。
- **集成测试**：用假的 `ToolProvider` 验证聚合、排序、超时、取消和错误隔离。
- **手动验收**：输入法、多屏幕、全屏空间、明暗模式、热键冲突、失焦隐藏、翻译 API 配置与错误提示、双击修饰键、组合输入打断与监听清理。
- **性能测试**：合成 5k 应用条目测匹配耗时；真机测文件搜索与面板显示延迟。

## 11. 风险与验证计划

| 风险 | 影响 | 缓解措施 | 验证节点 |
| --- | --- | --- | --- |
| NSPanel 非激活面板的键盘焦点行为不稳定 | 呼出后无法输入 | 先用最小原型验证 `.nonactivatingPanel` + `makeKeyAndOrderFront` + 第一响应者；必要时短暂激活应用并在隐藏时恢复 | M1 |
| 双击修饰键监听创建失败 | 双击呼出不可用 | 恢复上一个组合键或默认 ⌥ Space，显示实际回退提示；菜单栏仍可呼出 | M4 |
| `mdfind` 性能或权限受限 | 文件搜索慢/无结果 | 已确认输入的 120ms 防抖 + 2 秒超时 + 结果上限；超时保留部分结果，取消不误报失败 | M3 |
| 中文输入法与键盘导航冲突 | 无法正常输入中文或选择结果 | 不拦截输入法按键；在输入法组合期间仍允许搜索；手动验收覆盖拼音输入 | M1 |
| 全局热键与系统或其他应用冲突 | 无法呼出 | 注册失败时在设置页提示；允许更换热键 | M1 |

## 12. 未来演进

以下方向不影响 V1 架构，但真正实施前需要新的 ADR：

- 进程外 `SidecarProvider`：让任意语言实现 `ToolProvider`，复用现有搜索协议。
- 文件内容预览；文本与翻译全文已由独立工具窗口承载。
- 剪贴板历史。
- 应用名拼音/首字母匹配。
- 窗口管理、AI 对话等新工具类别。

## 13. 具名工具窗口

交互为“启动器 → 选择工具 → 新窗口”，每次执行都新建，包括同类 JSON。窗口内保留内容操作、置顶和命名，使用原生 macOS 窗口管理。参考 ADR0006。

- `ToolDefinition` / Provider：稳定工具入口与打开请求，无搜索阶段转换或剪贴板副作用。
- `ToolDocumentStore`：独立 UUID、标题、草稿、打开及最近关闭状态；不按工具类型复用会话。
- `ToolSession`：输入、模式、结果新鲜度、操作取消和版本控制。`ToolDraftEditor` 与原生编辑器共用每个窗口独立的 UndoManager，保证复合操作可完整撤销。JSON 编辑、Base64、URL 通过 DraftEditor.run 在有效计算完成后原地提交文本；提交期间保留成功状态，用户编辑与撤销仍会正常使旧结果失效。哈希／时间戳使用紧凑结果卡片。
- `JSONDocument` / `JSONDiff`：UTF-16 源范围、按原始数字词法保存、迭代解析/渲染/比较、精确数值与 Unicode 比较、2 MiB/256 层限制和前1000差异展示。
- `ToolWindowManager`：UUID到NSWindowController的映射、原生标题同步、失焦保留和焦点交接。
- `ToolTextEditor`：NSTextView、行号、查找、自动换行、临时语法属性；高亮不改文档或撤销历史。
- `ToolTheme`：暖灰与石墨的独立工作区配色，不影响启动器原有令牌。

关闭保留最多10份草稿供本次运行恢复，退出后不保存文本。窗口恢复不自动重新发起翻译。翻译只在窗口中明确点击后请求现有配置的服务。


## 网址快捷入口

`WebsiteShortcutConfiguration` 提供版本化 JSON、整份校验与规范化；`WebsiteShortcutStore` 持久保存独立 UserDefaults 数据。`WebsiteShortcutProvider` 通过现有 ToolProvider 协议动态注册自定义关键词，只做本机匹配，显式动作委托系统浏览器。自定义 gh 高于内置 GitHub 搜索，其他工具关键词在保存前拒绝冲突；未命中不回退公共搜索。独立 shortcut 结果分组不会被网页搜索的一条结果上限截断。

网址快捷入口直接读取本机 `WebsiteShortcutStore`。配置 version 3 在固定网址或多个具名环境地址之上增加子页面，version 1/2 仍可读取；页面使用统一的根路径/完整网址解析器和可选环境覆盖。`WebsiteShortcutProvider` 在本地依次解析系统、子页面与环境筛选，把每个实际地址展开成独立结果和稳定标识，结果模型的可选 `badge` 承载环境文字与色彩。手动编辑和 JSON 导入共用配置校验与原子保存，输入过程不访问站点，打开动作才交给默认浏览器。

设置的手动编辑和 JSON 模态编辑器共享同一 Store；导入先预览，保存替换整份，失败不提交。配置发布后组合层刷新启动器。查询变更重置键盘选中行，同查询更新保留选择。详见 [使用说明](website-shortcuts.md)。


## 启动器即时工具与动作

`CalculatorProvider` 是全局快速阶段的 search-only 提供者：`CalculatorEngine` 递归下降解析算式，带来源类别检查的 `UnitDefinition` 处理单位换算，结果回车写入剪贴板；不创建窗口、不联网。`QuickOpenProvider` 用 `QuickOpenParser` 识别 http(s)、`www.`、`~/`、绝对路径和 `file://`，已存在文件才显示结果。两者都可单独在设置中关闭，并通过 `dontstool.builtInProviderDefaultsV2Completed` 一次性进入老用户默认集合。

`LauncherPanelModel` 保存动作面板的展开与选中项；`PanelFooterView` 在面板打开时切换键位提示。`SearchField` 将 `⌘K` 转成动作面板开关，方向键、回车和 Esc 根据面板状态路由。应用、文件和网页结果扩展了退出应用、复制路径/链接等 `ItemAction`；动作面板只执行用户显式选择，不监听剪贴板，也不在后台触发系统操作。


## 应用动作与翻译服务

`GeminiProvider` 与 `IDEProjectProvider` 仅关键词路由，不参与普通全局查询。新增内置入口通过一次性默认启用迁移接入，保留原有禁用项；执行时再次检查当前开关。

Gemini 的 Core `GeminiConversationService` 在首次打开时等待应用完成激活；写入及发送前确认前台，用户切走会取消；发送已执行后的结果确认可在后台只读进行，仍绑定原窗口。随后验证草稿、新对话、精确问题和单次提交；Shell adapter 限定应用完整路径、PID与绑定窗口，后台 AX 遍历跳过历史列表，按已识别控件写入与提交。Esc监听仅在本次交接期间安装并清理；阶段等待和单次遍历分别有墙钟上限。用户输入只在明确执行时传递，不写URL、剪贴板或日志。

IDEA Discovery actor 按当前安装版本解析最近项目 XML，缓存文件指纹，过滤不存在或远程目录；官方应用参数启动通过 NSWorkspace 完成。执行前和异步路径校验后重新检查禁用/取消状态。


## 多端同步与备份

`CloudSync/` 目录存放独立部署的 Cloudflare Worker（`SyncHub` SQLite Durable Object + `SYNC_BUCKET` R2 存储桶）。`SyncHub` 串行维护单调递增 `revision` 游标与小于 64 KiB 的内联载荷；图片附件与超大载荷按 `SHA-256` 存入 R2 并跨设备去重；在线设备通过 Durable Object WebSocket Hibernation API 接收新 `revision` 推送通知，鉴权采用 Bearer Token + 常量时间哈希比对。

客户端 `CloudSyncCoordinator` 以本地为主（Local-First），通过 `SyncStateStore` 记录已同步基线与游标；离线并发修改同一便笺时，先将本地修改另存为「冲突副本」再应用远端版本，避免丢稿。`BackupArchiveService` 复用统一快照格式提供本地 `.zip` 导出与恢复（恢复前校验证书级 SHA-256 并在 `Application Support/DontsTool/Backups/` 自动留存安全快照）。翻译 API 密钥与同步密钥均保留在本机钥匙串，不进入云端或备份包。

应用启动时将 `RemoteTranslationService` 直接交给独立翻译窗口和划词卡片；用户需在翻译设置中填写 Responses 兼容接口地址、模型和 API 密钥。配置不完整时提示设置且不发送请求，服务失败或取消后不切换后端。系统翻译及语言包准备代码暂留在源码中，当前应用未接入。

划词翻译在达到设置的 300ms、500ms、1 秒或 2 秒阈值后，向已捕获且仍聚焦的源窗口发送 Cmd-C，等到剪贴板 changeCount 更新后读取新文字；不清空或还原剪贴板。窗口与安全输入校验在后台执行，取词或失败复用单张翻译卡片。显式关闭会使monitor请求失效，保留吞掉已触发mouse-up的状态，防止迟到取词结果重新弹窗或联网。

Gemini 交接在打开应用及新对话路由后显式激活应用窗口，避免已运行的 Gemini 留在后台。诊断只记录阶段和前台／输入框／新对话／可发送／已提交状态，不记录问题或历史正文。

## 本地便笺

`NotesProvider` 只在 `note` / `便笺` 关键词内检索标题和正文；全局仅显示入口，避免便笺内容混入普通应用查询。现有网站或引擎使用 `note` 时保留其路由，中文入口继续可用。

`LocalNoteStore` 持有版本化记录，每篇一个 UUID 目录，JSON 原子写入，图片验证后存入自有 `assets/`；富文本 JSON 为权威，Markdown 为交换格式。`LocalNoteSession` 缓存最新正文并在 350 ms 后保存，区分编辑错误与磁盘错误。关闭／退出在同一 JS task 取得快照并冻结编辑，落盘成功才关闭；失败或取消退出恢复编辑。最近删除移动整个目录，旧保存不能重建已删除记录。

`LocalNoteEditorBridge` 通过消息协议驱动离线 Tiptap，资源和图片只通过绑定当前 UUID 的 `donts-note://` scheme 读取。CSP 禁止网络资源；链接只由用户主动点击后交给系统。剪贴板仅在显式粘贴时读取，图片复制后使用相对引用，跨便笺复制会重新归属。正文移除图片不提前删除附件，保障撤销；导出只包含当前正文引用。

源码与生成资源一起维护，CI 验证 bundle 一致性；使用与数据边界见 [便笺说明](local-notes.md)。
