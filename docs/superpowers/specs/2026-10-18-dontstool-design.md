# DontsTool V1 详细设计

> 状态：已确认，进入实现
> 日期：2026-10-18
> 架构背景：[架构总览](../../architecture.md)

## 1. 目标与范围

### 1.1 V1 必须提供

1. 全局热键呼出/隐藏启动器面板，默认 `Option + Space`，可配置为组合键或双击修饰键。
2. 应用搜索与启动。
3. 文件搜索与打开。
4. 文本小工具：JSON、Base64、URL 编解码、时间戳、UUID、Hash。
5. 网页搜索：关键词直达 + 无本地结果时的兜底。
6. 翻译：用户配置的 OpenAI Responses 兼容 API，网页翻译兜底。
7. 设置页与本地持久化。
8. 内置 `ToolProvider` 扩展模型。

### 1.2 V1 不提供

- 运行时插件 / 插件市场 / 多语言插件
- 剪贴板历史、窗口管理、OCR、AI 对话
- 云同步、账号、遥测
- 多语言界面（仅简体中文）
- App Store 沙盒发布

### 1.3 验收总则

- 所有 V1 功能可以全程用键盘完成。
- 应用常驻时不发起任何后台网络请求。
- 任一 Provider 失败不得导致主界面崩溃或其他 Provider 结果丢失。
- 性能预算见第 8 节。
- 手动验收清单见第 9.3 节。

## 2. 交互设计

### 2.1 面板

| 属性 | 值 |
| --- | --- |
| 尺寸 | 640 × 420 pt，列表内容超出时滚动 |
| 位置 | 鼠标所在屏幕，水平居中，距屏幕顶部约 18% |
| 背景 | 半透明材质 + 设计令牌着色（浅色 `#FFFFFFD9` / 深色 `#242528F0`），圆角 14pt，细边框；视觉以 `design/` 设计稿为准 |
| 层级 | `.floating`，`.canJoinAllSpaces`，`.fullScreenAuxiliary` |
| 行为 | 再次按热键、`Esc`、点击面板外、执行动作后隐藏；提示类动作（填入关键词）保持面板打开 |
| 焦点 | 显示时搜索框获得键盘焦点；隐藏后恢复此前的前台应用 |
| 主题 | 跟随系统明暗模式 |
| 菜单栏 | 常驻 D 形图标，菜单仅包含“打开启动器”与“退出 DontsTool”；设置从面板齿轮或 `Cmd + ,` 进入 |

面板结构：

```text
┌──────────────────────────────────────────────┐
│  [搜索框：输入应用名、文件或关键词]           │
├──────────────────────────────────────────────┤
│  [图标] 结果标题                    动作提示 │
│  [图标] 结果标题                    动作提示 │
│  ...                                         │
├──────────────────────────────────────────────┤
│  ↑↓ 选择   ↵ 执行   esc 关闭                  │
└──────────────────────────────────────────────┘
```

### 2.2 键盘

| 按键 | 行为 |
| --- | --- |
| `↑` / `↓` | 移动选中项 |
| `Enter` | 执行主操作 |
| `Cmd + Enter` | 执行次操作（存在时，如“在 Finder 中显示”） |
| `Esc` | 关闭面板 |
| `Cmd + ,` | 打开设置（先关闭面板） |
| `Cmd + R` | 重新扫描应用索引（面板显示时，给出 toast 反馈） |

鼠标：单击结果项即执行主操作；悬停高亮。

### 2.3 空查询状态

- 第一组「常用」：按使用频率与最近使用排序的前 8 个应用；没有使用记录时按名称排序。
- 第二组「工具」：已启用的工具提示，例如 `json` 格式化 JSON、`b64` Base64 编码、`tr` 翻译、`g` 网页搜索。
- 文件搜索与网络请求不触发。

### 2.4 状态

| 状态 | 展示 |
| --- | --- |
| 空查询 | 常用应用 + 工具提示 |
| 有查询、快速结果已出、慢速进行中 | 快速结果 + 底部“正在搜索文件…”状态行 |
| 无任何结果 | “没有找到结果” +（查询非空时）网页搜索兜底项 |
| Provider 出错 | 不展示错误页；记录日志，底栏显示简短状态（如“文件搜索不可用”） |
| 执行出错 | Toast 提示，面板保持打开 |

### 2.5 反馈

- 复制成功：Toast「已复制到剪贴板」。
- 剪贴板为空：Toast「剪贴板为空」。
- 翻译进行中：底栏显示进度文案，禁止重复触发。
- 操作失败：Toast 显示可读原因；不弹模态框（设置与系统权限提示除外）。

### 2.6 界面实现架构（2026-10-18 设计稿对齐）

视觉与交互以仓库内 `design/` 设计稿为准（`DESIGN.md` 令牌、`MOTION.md` 动效、五个 HTML 场景）。实现分层：

- **AppKit 薄壳**：`LauncherPanel`（NSPanel 行为）、`HotKeyManager`、`SearchField`（键盘/IME/快捷键，已验证）、`SettingsWindowController`、菜单栏。
- **SwiftUI 内容**：面板（搜索头、分组结果、底栏、Toast）与设置窗口全部由 SwiftUI 视图承载，经 `NSHostingView` 嵌入。
- **设计令牌层**：`Sources/DontsTool/UI/DesignSystem/` 下 `Theme`（浅/深动态色与字体）、`Metrics`（尺寸）、`Motion`（时长/缓动，遵循减少动态效果）。视图禁止写死色值与尺寸。
- **组件库**：`UI/Components/` 下 `IconTile`、`ResultRowView`、`GroupHeader`、`KeyCap`、`ActionCapsule`、`ShortcutTag`、`PanelFooterView`、`ToastView` 等，设置页组件在 `UI/Settings/`。
- **可测试状态层**：`LauncherPanelModel`（DontsToolCore）持有结果分组、键盘选择、状态栏与 Toast 文本；窗口行为留在壳层。
- 图标模型扩展为 `ItemIcon.symbol(name:tint:)` 与 `.glyph(text:tint:)`，配合 `IconTint` 着色块；提示类结果带 `keyword` 行尾标签。
- 动效：呼出 220ms（透明度 + 上移 8pt + 缩放 .985→1）、收起 140ms、选中/悬停 100–140ms；系统开启减少动态效果时降级为 1ms。

## 3. 数据模型与扩展协议

```swift
enum SearchMode: Equatable {
    case global
    case keyword(providerID: String, keyword: String, argument: String)
}

struct SearchContext {
    let rawQuery: String
    let mode: SearchMode
    let frontmostBundleID: String?
}

enum ResultGroup: Int, Comparable {
    case app = 0
    case tool = 1
    case file = 2
    case web = 3
}

enum ItemIcon {
    case application(path: String)
    case file(path: String)
    case symbol(name: String)
}

struct ItemAction {
    let id: String
    let title: String
    let run: @MainActor () async throws -> Void
}

struct SearchItem: Identifiable {
    let id: String              // providerID + 本地 ID，全局唯一
    let providerID: String
    let group: ResultGroup
    let title: String
    let subtitle: String?
    let icon: ItemIcon
    let score: Double
    let canonicalKey: String    // 去重依据，见 4.4
    let actions: [ItemAction]   // 第一个为主操作
}

enum SearchPhase: Sendable {
    case fast
    case slow
}

@MainActor
protocol ToolProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var keywords: [String] { get }   // 空数组表示不支持关键词模式
    var priority: Int { get }        // 越大越靠前
    var isEnabled: Bool { get set }
    var phase: SearchPhase { get }   // 默认 .fast
    var statusNotice: String? { get } // 最近一次搜索的简短降级说明，默认 nil

    func search(_ context: SearchContext) async -> [SearchItem]
}

extension ToolProvider {
    var phase: SearchPhase { .fast }
    var statusNotice: String? { nil }
}
```

约定：

- 所有 Provider 与 UI 均在主 Actor 上；耗时工作在 Provider 内部转移到后台任务，返回前回到主 Actor。
- `SearchItem.id` 必须稳定，用于选中状态；`canonicalKey` 用于跨 Provider 去重。
- 动作通过闭包携带，避免为每种结果定义枚举；闭包由 Provider 创建并持有必要数据。
- Provider 不得抛出未捕获错误；`search` 内部处理失败并返回空数组或错误提示项。

## 4. 查询解析与搜索流程

### 4.1 解析

1. 去除首尾空白。
2. 取第一个 token；若它与某个已启用 Provider 的关键词完全匹配（不区分大小写），进入关键词模式，剩余文本为参数。
3. 若多个 Provider 声明同一关键词，`priority` 高者胜出；启动时检测并记录冲突日志。
4. 其他情况进入全局模式。

### 4.2 两阶段搜索

| 阶段 | 触发 | Provider | 超时 |
| --- | --- | --- | --- |
| 快速 | 每次文本变化 | AppProvider、TextToolsProvider、WebSearchProvider | 无（内存操作） |
| 慢速 | 停止输入 120ms | FileProvider | 300ms |

- 快速阶段结果立即渲染。
- 慢速结果到达后按分组合并；如果用户已输入新查询，丢弃旧结果。
- 每次查询递增 generation，回调时校验 generation。
- 关键词模式下只查询对应 Provider；全局模式下查询所有已启用 Provider（文本工具仅返回关键词提示，不执行转换）。

### 4.3 排序

全局模式先按分组：应用 → 工具 → 文件 → 网页；组内按分数降序。

```text
finalScore = matchScore + usageBoost + recencyBoost
matchScore: 完全匹配 1000，前缀 900，词首前缀 800，子串 700，子序列 300–600
usageBoost = min(100, 15 × log2(1 + 使用次数))
recencyBoost: 24 小时内 +50，7 天内 +20，其余 0
```

- 匹配不区分大小写和重音符号。
- 空查询不使用匹配分，只按使用频率和最近使用排序。
- 结果上限：应用 8、工具 8、文件 12、网页 1。

### 4.4 去重

- 应用：`bundle path`
- 文件：标准化后的绝对路径
- 网页：最终 URL
- 工具：`keyword + normalized argument`
- 重复项保留分数更高者。

### 4.5 取消与超时

- `SearchCoordinator` 持有当前慢速搜索任务，新查询到来时取消。
- `FileProvider` 取消时终止仍在运行的 `mdfind` 进程。
- 超时后返回已收集的部分结果（最多 12 条），不阻塞 UI。

### 4.6 错误隔离

- 单个 Provider 的错误只影响自身结果。
- 记录 `os.Logger`，分类为 `search`、`provider`、`translation`、`index`。
- 用户可见的状态只展示简短原因，不展示堆栈。

## 5. 工具详细设计

### 5.1 AppProvider（核心）

**索引来源**

- `/Applications`
- `/System/Applications`
- `/System/Applications/Utilities`
- `~/Applications`
- 以上目录的一层子目录

**扫描规则**

- 只收集 `.app` 包，跳过包内嵌套的 helper（路径中出现 `.app/`）。
- 读取 `CFBundleDisplayName`（回退 `CFBundleName`、文件名）、`CFBundleIdentifier`、路径。
- 跳过 `LSBackgroundOnly = true` 的应用。
- 在后台任务中扫描，完成后在主 Actor 发布快照。
- 启动时扫描一次；`Cmd + R` 与设置页按钮可手动重扫；扫描失败保留旧快照。

**图标**

- `NSWorkspace.shared.icon(forFile:)`，缩放到 32×32，按路径 + 修改时间缓存到 `NSCache`。

**排序**

- 模糊匹配名称；带使用量与最近使用加成。
- 空查询展示常用应用。

**执行**

- `NSWorkspace.shared.openApplication(at:configuration:completionHandler:)`。
- 失败时 Toast「无法打开应用」并记录日志。

**验收**

- 输入 `chr`，Chrome 出现在前三条；回车后面板关闭且应用激活。
- 新安装的应用在重新扫描后可见。

### 5.2 FileProvider（核心）

**实现**

- 调用 `/usr/bin/mdfind -name <query>`，参数数组传递，不经过 shell。
- 停止输入 120ms 后启动；超时 300ms；最多读取 200 行原始结果。
- 过滤 `/System/`、`/Library/`、`/private/`、`/Users/Shared/`、隐藏路径、`.app` 包。
- 按文件名匹配质量排序，取前 12 条。
- 无 Spotlight 或 `mdfind` 失败：隐藏文件分组，底栏提示「文件搜索不可用」。

**展示**

- 标题为文件名，副标题为 `~` 缩写后的父目录路径，中间截断。

**执行**

- 主操作：`NSWorkspace.shared.open(URL(fileURLWithPath:))`。
- 次操作：`NSWorkspace.shared.activateFileViewerSelecting([url])`（`Cmd + Enter`）。

**验收**

- 输入常见文件名片段，300ms 内出现结果。
- 回车打开默认应用；`Cmd + Enter` 在 Finder 中定位。

### 5.3 TextToolsProvider

| 关键词 | 功能 | 输入 | 示例 |
| --- | --- | --- | --- |
| `json` | 格式化 JSON | 参数，空则用剪贴板 | `json {"a":1}` |
| `b64` | Base64 编码 | 参数，空则用剪贴板 | `b64 hello` |
| `b64d` | Base64 解码 | 参数，空则用剪贴板 | `b64d aGVsbG8=` |
| `url` | URL 编码（RFC 3986） | 参数，空则用剪贴板 | `url a b` |
| `urld` | URL 解码 | 参数，空则用剪贴板 | `urld a%20b` |
| `ts` | 时间戳与日期互转 | 参数；空则显示当前时间 | `ts 1700000000` |
| `uuid` | 生成 UUID v4 | 无 | `uuid` |
| `md5` / `sha1` / `sha256` | 哈希（小写十六进制） | 参数，空则用剪贴板 | `sha256 hello` |

**行为**

- 关键词 + 参数：实时计算并在结果行展示截断预览（最多 80 字符），主操作「复制结果」。
- 参数为空：结果标题如「格式化剪贴板 JSON」；执行时才读取剪贴板，避免每次输入读取剪贴板。
- JSON 主操作格式化复制，次操作压缩复制（`Cmd + Enter`）。
- 时间戳支持 10 位秒、13 位毫秒；日期支持 `yyyy-MM-dd HH:mm:ss` 与 ISO 8601。
- 非法输入：结果行副标题显示错误原因，执行时 Toast 相同原因，不崩溃。
- 复制使用 `NSPasteboard.general`，成功后 Toast「已复制到剪贴板」。

**已知限制（V1）**

- JSON 经过 `JSONSerialization` 处理，对象键顺序可能被重排。
- 输入直接来自搜索框，超长文本体验一般；结果预览面板留到后续版本。

**验收**

- 每个关键词的示例可用，输出正确。
- 非法 JSON / Base64 有可读错误提示。
- 连续执行不泄漏、不崩溃。

### 5.4 WebSearchProvider

| 关键词 | 目标 | URL 模板 |
| --- | --- | --- |
| `g` | Google | `https://www.google.com/search?q=` |
| `bing` | Bing | `https://www.bing.com/search?q=` |
| `bd` | 百度 | `https://www.baidu.com/s?wd=` |
| `ddg` | DuckDuckGo | `https://duckduckgo.com/?q=` |
| `gh` | GitHub | `https://github.com/search?q=` |

- 参数使用 RFC 3986 百分号编码。
- 参数为空时展示提示项，不打开浏览器。
- 全局模式下，若没有任何应用/工具/文件命中且查询非空，追加一条兜底项「用 <默认引擎> 搜索 “…”」。
- 默认引擎可设置：Google、Bing、百度、DuckDuckGo，默认 Google。
- 执行使用 `NSWorkspace.shared.open(url)`；失败 Toast。

**验收**

- `g swift concurrency` 打开默认浏览器搜索页。
- 无本地结果时出现兜底项。

### 5.5 TranslationProvider

**关键词**：`tr`

主翻译项归入「工具」分组，网页翻译兜底项归入「网页」分组，避免被网页分组上限截掉主项。

**目标语言**

- 设置项，默认跟随系统（简体中文或英文），可选常见语言。
- 源语言自动识别（NaturalLanguage，本地完成）。

**翻译后端：用户配置的 OpenAI Responses 兼容 API**

- 2026-10-18 决策：放弃系统 Translation 框架。原因：首用语言对需要下载资源，系统的下载确认模态会挂在启动器的隐形宿主窗口上，用户无法点击，会话永久等待（实测日志 `App termination blocked by modal sheet`）。
- 改为调用用户配置的 HTTP 端点：`POST {baseURL}/responses`，请求体 `{model, instructions, input}`，取 `output_text` 或 `output[].content[].text`（`type == "output_text"`）拼接为译文。
- 配置项：接口地址（baseURL）、模型（model）、API 密钥。密钥存 macOS 钥匙串（`KeychainSecretStore`），baseURL/model 存 UserDefaults。默认全部留空。
- 仅在用户显式执行翻译时发送文本；无后台网络、无遥测。

**搜索结果（关键词模式）**

1. 已配置：主项「翻译：<参数摘要>」——调用配置的 API；次项「在网页中翻译」——Google Translate（`sl=auto`）。
2. 未配置：「配置翻译 API」提示项（回车打开设置页）+ 网页兜底项。
3. 源语言与目标语言相同：提示项，不调用接口。

**流程**

- 参数为空时使用剪贴板内容，执行时读取。
- 翻译期间在面板底部显示「正在翻译…」；30 秒超时按失败处理。
- 成功后复制译文到剪贴板，Toast 展示译文前 80 字符。
- 失败时 Toast 服务端返回的可读错误（`error.message` 或 HTTP 状态），面板保持打开；用户可执行网页翻译项。

**隐私**

- 文本发送到用户自己配置的端点；应用不记录、不上报文本与密钥。

**验收**

- 配置密钥后 `tr hello` 能翻译为设定目标语言并复制。
- 未配置时出现「配置翻译 API」与网页兜底项。
- 服务端错误 / 超时 / 空结果有可读反馈。

## 6. 设置与持久化

### 6.1 设置页

| 分区 | 内容 |
| --- | --- |
| 通用 | 全局热键录制、开机启动、外观说明、使用说明 |
| 搜索 | 默认搜索引擎、启用文件搜索 |
| 工具 | 各 Provider 开关（应用、文件、文本工具、网页搜索、翻译） |
| 翻译 | 目标语言、翻译 API 接口地址 / 模型 / 密钥（钥匙串） |
| 索引 | 已索引应用数量、重新扫描按钮（⌘R） |
| 关于 | 版本号、文档链接 |

### 6.2 热键录制

- 点击后进入录制状态，显示当前按键组合。
- 组合键至少包含一个修饰键 + 一个非修饰键；也可以双击 `⌘` / `⌥` / `⌃` / `⇧` 中的一个作为触发方式；`Esc` 取消。
- 保存后立即重新注册；组合键注册失败则恢复旧热键并显示内联错误。
- 双击修饰键仅监听全局和本地 `flagsChanged`，不申请输入监控或辅助功能权限；用系统事件计数及最近按键时间打断普通输入，不读取按键内容。两次均为短按，第二次松开时触发；不轮询。监听创建失败时保留组合键回退入口。

### 6.3 开机启动

- 使用 `SMAppService.mainApp` 注册/注销。
- UI 状态以系统返回为准；失败时提示前往“系统设置 → 通用 → 登录项”。

### 6.4 持久化

`UserDefaults`，键名前缀 `dontstool.`：

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `dontstool.hotkey.kind` | String | `combination` / `doubleTap` |
| `dontstool.hotkey.keyCode` | Int | 组合键键码；双击模式下为 0 |
| `dontstool.hotkey.modifiers` | UInt | 修饰键掩码；双击模式下为被双击的修饰键位 |
| `dontstool.defaultSearchEngine` | String | `google` / `bing` / `baidu` / `ddg` |
| `dontstool.enabledProviders` | [String] | 启用的 Provider ID |
| `dontstool.fileSearchEnabled` | Bool | 是否启用文件搜索 |
| `dontstool.translationTarget` | String | BCP-47 语言代码 |
| `dontstool.translationAPIBaseURL` | String | 翻译 API 接口地址，默认空 |
| `dontstool.translationAPIModel` | String | 翻译模型名，默认空 |
| `dontstool.usage.records` | Data | JSON 编码的使用记录 |
| `dontstool.hasCompletedOnboarding` | Bool | 首次运行提示是否已展示 |

- 翻译 API 密钥不存 UserDefaults，存登录钥匙串通用密码项（service `com.dontstool.secrets`，account `translationAPIKey`）。
- 使用记录在内存中更新，2 秒防抖写入；没有账号系统。

### 6.5 首次运行

- 首次启动时显示一个轻量欢迎窗口：说明默认热键、菜单栏位置、文件搜索可能需要的权限。
- 提供“打开设置”按钮，关闭后写入 `dontstool.hasCompletedOnboarding = true`。
- 之后不再自动弹出；使用说明保留在设置的“通用”页。

## 7. 错误处理与降级

| 场景 | 用户可见行为 | 内部处理 |
| --- | --- | --- |
| 组合键注册失败 | 恢复旧热键并提示；菜单栏仍可打开面板 | 记录系统错误码 |
| 双击修饰键监听创建失败 | 提示当前回退组合键；菜单栏仍可打开面板 | 恢复上一个组合键或默认 ⌥ Space |
| 应用索引扫描失败 | 保留上一次快照；设置页显示提示 | 记录日志 |
| `mdfind` 超时 | 展示已收集结果，底栏状态 | 终止进程 |
| `mdfind` 不可用 | 隐藏文件结果 | 记录日志 |
| 文本工具输入非法 | 结果行内联错误 | 不抛异常到 UI |
| 剪贴板为空 | Toast 提示 | 不执行转换 |
| 翻译 API 未配置 | 显示「配置翻译 API」提示项 + 网页兜底项 | 不发起网络请求 |
| 翻译执行失败 | Toast 错误；面板保持 | 记录日志 |
| 打开应用/文件/URL 失败 | Toast 错误 | 记录日志 |
| Provider 内部异常 | 该 Provider 返回空结果 | 其他结果不受影响 |

## 8. 性能预算与测量

| 指标 | 预算 | 测量方式 |
| --- | --- | --- |
| 热键到面板可见 | ≤ 100ms p95 | `os_signpost` + 手动秒表 |
| 输入到快速结果 | ≤ 50ms p95 | signpost 区间 |
| 文件结果 | ≤ 300ms p95（用户可见） | signpost + 真机；mdfind 限定用户目录（`-onlyin ~`），超时返回部分结果 |
| 冷启动到可呼出 | ≤ 1.5s | 启动打点 |
| 常驻内存 | ≤ 150MB | Activity Monitor / Instruments |
| 空闲 CPU | ≤ 0.5% | Activity Monitor |

优化手段：

- 应用索引与图标缓存常驻内存。
- 两阶段搜索 + 取消 + 结果上限。
- 使用 `NSTableView` 复用行视图，避免每次输入重建全部视图。
- 使用统计与设置延迟写入。
- 不在主线程做文件 I/O。

## 9. 测试计划

### 9.1 单元测试

- `FuzzyMatcher`：完全匹配、前缀、词首、子串、子序列、无匹配、大小写、重音、中英文混合。
- `QueryParser`：全局模式、关键词模式、大小写、空参数、关键词冲突。
- 排序：使用频率、最近使用、分组优先级。
- 文本转换：JSON 合法/非法、Base64 编解码、URL 编解码、时间戳秒/毫秒、日期解析、UUID 格式、Hash 已知向量。
- `WebSearchProvider`：URL 编码、默认引擎、空参数。
- `AppIndex`：嵌套 `.app` 过滤、显示名回退、背景应用过滤。
- 去重与结果上限。

### 9.2 集成测试

- 使用 `MockProvider` 验证快速/慢速阶段、超时、取消、排序、去重、Provider 错误隔离。
- 使用 Mock 剪贴板验证文本工具的空参数路径。
- 使用 Mock 打开器验证执行动作与使用记录写入。

### 9.3 手动验收清单

- [ ] 热键呼出/隐藏、再次按热键切换、失焦隐藏、`Esc` 隐藏。
- [ ] 呼出后立即输入，面板焦点正确，隐藏后前台应用恢复。
- [ ] 中文输入法拼音输入、候选词选择、上屏正常。
- [ ] 多显示器：面板出现在鼠标所在屏幕。
- [ ] 全屏应用与其他 Space 下可呼出。
- [ ] 明暗模式外观正常。
- [ ] 应用搜索、文件搜索、打开与 Finder 定位。
- [ ] 每个文本工具的正常与错误输入。
- [ ] 网页搜索关键词与兜底。
- [ ] 配置密钥后翻译成功；未配置时出现配置提示；服务端错误与超时有可读反馈。
- [ ] 设置持久化，重启后热键与开关生效。
- [ ] 开机启动开关。
- [ ] 无 Spotlight / 无完全磁盘访问时的降级表现。
- [ ] 长时间驻留内存与 CPU 无明显增长。

### 9.4 性能测试

- 合成 5k 应用名称，连续 1k 次查询，记录 p50/p95 匹配耗时。
- 真机测试 `mdfind` 在常见关键词下的延迟。
- Instruments 检查启动、搜索、滚动时的 CPU 与内存。

## 10. 实施里程碑

### M1 基础壳与原生手感

交付：XcodeGen 工程 + Makefile 构建 `.app`、菜单栏、浮动面板、全局热键、应用索引与启动、空状态、基础列表。

验收：热键到面板 < 100ms；输入可过滤应用；回车启动；`Esc` / 失焦隐藏；焦点恢复。

### M2 扩展模型与轻工具

交付：`ToolProvider`、`ToolRegistry`、`SearchCoordinator` 两阶段搜索、文本工具、网页搜索、使用统计与排序、Toast。

验收：所有文本工具示例可用；关键词直达网页搜索；无本地结果时兜底；Provider 错误不影响其他结果。

### M3 文件、翻译与设置

交付：`FileProvider`（mdfind）、`TranslationProvider`、完整设置页、开机启动、错误与降级状态。

验收：文件搜索 300ms 内出结果并可打开/定位；翻译成功与兜底路径可用；设置重启后生效。

### M4 打磨与验收

交付：性能优化、无障碍标签、首次运行引导、打包与签名脚本、文档同步。

验收：第 8 节预算全部达标；第 9.3 节清单通过。

## 11. 后续工作

- `SidecarProvider`：进程外多语言工具，复用 `ToolProvider` 协议。
- 结果预览面板（完整文本、翻译全文、文件详情）。
- 剪贴板历史。
- 应用名拼音/首字母匹配。
- 窗口管理、AI 等新工具类别。

架构层面的变更必须先新增 ADR，再更新架构文档。
