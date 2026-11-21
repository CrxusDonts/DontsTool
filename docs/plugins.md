# 插件使用与开发指南

自 `v0.3.0` 起，DontsTool 采用微内核宿主加进程外 Sidecar 插件的扩展模式。本文前半部分说明如何安装和管理插件，后半部分说明协议规范与插件开发。

## 一、使用与管理插件

### 1. 官方插件源与一键安装

打开 DontsTool 的 **设置 → 插件**，顶部显示当前已安装的插件列表，下方展示已订阅的插件源。

应用默认内置官方插件仓库 [CrxusDonts/DontsTool-Plugins](https://github.com/CrxusDonts/DontsTool-Plugins)。首次打开「插件」页时会自动拉取目录，包含以下插件：

| 插件 ID | 名称 | 触发关键词 | 运行模式 | 备注与系统授权 |
| --- | --- | --- | --- | --- |
| `com.donts.quick-ai` | AI 快问 | `ai`、`ask`、`问` | `daemon` | 需宿主 `≥ 0.4.0`；申请 `openAI` 与 `prefill` 权限，复用宿主「AI 与翻译」大模型配置，唤起原生流式对话窗口 |
| `com.donts.kill-process` | 结束进程 | `kill`、`kp`、`进程` | `daemon` | 自动排除宿主与自身 PID，支持 `:端口` 查找 |
| `com.donts.idea-projects` | IDEA 项目 | `idea` | `daemon` | 读取本机 JetBrains 最近项目 XML，支持本地目录路径 |
| `com.donts.file-search` | 文件搜索 | `file` | `oneshot` | 调用 `/usr/bin/mdfind`；检索受保护目录可按需授「完全磁盘访问」 |
| `com.donts.chrome` | Google Chrome | `chrome`、`ch`、`tab`、`tabs`、`bm`、`书签`、`标签页` | `daemon` | 读取/控制标签页需 macOS「自动化」权限；拒绝后书签与历史仍可用 |
| `com.donts.terminal-finder` | 终端与访达 | `tf`、`ft`、`term`、`终端` | `daemon` | 读取访达或 iTerm2 / 系统终端状态需 macOS「自动化」权限 |
| `com.example.hello-sidecar` | Hello Sidecar 示例 | `hello` | `oneshot` | Python 示例插件，非官方推荐项，可按需单独安装 |

在官方插件源卡片顶部点击「安装全部推荐插件」，可以一次性校验并安装全部 6 个官方插件；也可以在列表中逐条点击「安装」或「更新」。

### 2. 添加自定义 GitHub 插件源

在「插件源与安装」输入框中填入以下任一格式后点击「添加源」：

- GitHub 仓库简写：`owner/repo`
- GitHub 仓库链接：`https://github.com/owner/repo`
- 直接索引链接：`https://example.com/path/to/catalog.json`（仅允许 HTTPS）

自定义源持久化在 `UserDefaults`（key：`dontstool.plugins.sources`），随时可以刷新或移除。官方源不可移除。

对于 `owner/repo` 形式的 GitHub 源，安装器按以下顺序查找清单，避免触发 GitHub API 的每小时 60 次匿名限流：

1. `https://github.com/<owner>/<repo>/releases/latest/download/catalog.json`
2. `https://raw.githubusercontent.com/<owner>/<repo>/main/catalog.json`
3. `https://raw.githubusercontent.com/<owner>/<repo>/master/catalog.json`
4. 单插件仓回退：`https://raw.githubusercontent.com/<owner>/<repo>/main/manifest.json`（自动包装为单条目录项，安装时下载仓库 `main` 或 `master` 归档）

### 3. 安全校验、权限确认与跨源冲突保护

点击「安装」或「更新」采用两步提交流程，在真正写入插件目录前完成全部校验：

1. **下载与校验（`inspectPackage`）**：
   - 检查 `minHostVersion` 是否满足当前宿主版本；
   - 仅允许 HTTPS 下载，单包体积上限 100 MiB；
   - 若目录提供了 `sha256`，使用 `CryptoKit.SHA256` 严格核对压缩包哈希，不匹配立即中止；
   - 使用 `/usr/bin/ditto -x -k` 解压到临时 staging 目录，递归检查并拒绝指向包目录之外的符号链接，自动为 `bin/*` 和入口文件补齐可执行权限；
   - 用 `PluginManifestLoader` 校验 `manifest.json`，并核对 `manifest.id` 与目录条目 `id` 一致；
   - 读取已安装插件目录下的 `.install-meta.json`，检测是否来自不同的源仓库。
2. **权限确认弹窗**：
   - 展示插件名称、ID、版本号（更新时显示旧版到新版）、来源仓库、触发关键词、SHA-256 校验状态以及申请的全部宿主权限；
   - 如果检测到同名插件已由其他源安装，会弹出跨源冲突警告，必须手动勾选确认覆盖后才可继续。
3. **原子安装与热重载（`commitInstall`）**：
   - 写入 `.install-meta.json` 记录版本、来源仓库与哈希；
   - 先关闭旧版本插件进程，再将新目录原子替换到 `~/Library/Application Support/DontsTool/Plugins/<pluginID>/`（失败自动回滚备份目录）；
   - 自动调用 `PluginManager.reload()` 热加载，无需重启 DontsTool。取消弹窗时会自动清理临时目录。

### 4. 更新、启停、卸载与本地调试

- **检查更新**：在「已安装插件」区点击「检查更新」，会刷新所有已订阅源；有新版时行内会显示版本变化和「更新」按钮。
- **启用 / 停用**：通过行右侧开关控制，状态保存在 `PluginSettingsStore`。停用后立即从搜索结果中排除。
- **卸载**：点击「卸载」并确认，宿主会先验证目标路径位于用户插件目录内，再终止插件进程、删除目录并热重载；已保存的插件偏好设置不会丢失。
- **本地开发调试**：将本地插件目录软链接到 `~/Library/Application Support/DontsTool/Plugins/<pluginID>`，再点击「重新加载」即可生效（此类目录在列表中标记为「本地插件」）。

## 二、开发插件

任何可以读写标准输入/输出（stdin / stdout）并输出 UTF-8 JSON 的可执行文件或脚本（Swift、Go、Rust、Python、Node.js、Shell 等）都可以作为 DontsTool 插件。

### 1. 插件目录结构

一个标准插件包的结构如下：

```text
com.example.my-plugin/
├── manifest.json          # 必填：插件声明（schemaVersion: 1）
├── bin/
│   └── my-plugin          # 必填：入口可执行文件或脚本（需 chmod +x）
└── assets/                # 可选：包内自定义图标等静态资源
    └── icon.png
```

所有相对路径（命令入口、图标等）均限制在插件目录内部，路径穿越（`..` 或逃逸符号链接）会被拒绝。

### 2. `manifest.json` 规范

```json
{
  "schemaVersion": 1,
  "id": "com.example.hello-sidecar",
  "name": "Hello Sidecar",
  "version": "1.0.0",
  "description": "演示外部 Sidecar 插件：支持快速输出与回调动作",
  "minHostVersion": "0.2.14",
  "keywords": ["hello"],
  "supportsGlobalSearch": false,
  "globalAliases": ["hello", "sidecar", "插件示例"],
  "phase": "slow",
  "runsOnEmptyArgument": true,
  "priority": 30,
  "homeEntry": {
    "canonicalKey": "hello:entry",
    "title": "Hello Sidecar",
    "subtitle": "输入 hello 加内容体验外部插件协议",
    "symbol": "puzzlepiece.extension",
    "tint": "teal",
    "score": 820
  },
  "runtime": {
    "mode": "oneshot",
    "command": ["/usr/bin/env", "python3", "bin/run"],
    "timeoutMs": 1500
  },
  "permissions": [
    "clipboard.write",
    "prefill",
    "toast",
    "refresh"
  ],
  "preferences": [
    {
      "key": "greeting",
      "type": "string",
      "title": "默认问候语",
      "required": false,
      "defaultValue": "你好"
    }
  ]
}
```

字段说明：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `schemaVersion` | 是 | 固定为 `1` |
| `id` | 是 | 反向域名风格唯一标识，仅允许小写字母、数字、`.`、`-`、`_`，且包含至少一个 `.` |
| `name` | 是 | 插件显示名称 |
| `version` | 是 | 语义化版本号（如 `1.0.0`），用于更新比较 |
| `description` | 否 | 简短介绍，展示在设置页 |
| `minHostVersion` | 否 | 最低兼容的 DontsTool 版本（如 `0.2.14` 或 `0.3.0`），不满足时拒绝安装和加载 |
| `keywords` | 是 | 非空触发关键词数组（自动转小写并去重）；若与用户自定义网址或搜索引擎冲突，用户自定义优先 |
| `supportsGlobalSearch` | 否 | 默认 `false`；是否参与无关键词的全局搜索（建议保持 `false`，改用 `globalAliases` 做声明式发现） |
| `globalAliases` | 否 | 全局搜索别名列表；命中时由宿主直接展示 `homeEntry`，不唤醒子进程 |
| `phase` | 否 | `"slow"`（默认）或 `"fast"`；多数插件建议 `"slow"` |
| `runsOnEmptyArgument` | 否 | 默认 `false`；用户输入关键词后未跟参数（如 `kill `）时是否触发查询 |
| `priority` | 否 | 优先级；外部用户插件会被钳制在 `1...50`（默认 `30`），不会压过内置核心工具 |
| `icon` | 否 | 包内相对路径图标 |
| `homeEntry` | 否 | 声明式首页/全局发现入口：`canonicalKey`、`title`、可选 `subtitle`、`symbol`、`image`、`tint`、`score`（默认 `850`） |
| `runtime.mode` | 是 | `"oneshot"`（每次请求启动新进程）或 `"daemon"`（长驻进程复用，自动按空闲回收和崩溃重启） |
| `runtime.command` | 是 | 启动命令数组，例如 `["bin/my-plugin"]` 或 `["/usr/bin/env", "python3", "bin/run"]`（不经过 shell） |
| `runtime.timeoutMs` | 否 | 单次请求超时毫秒数，钳制在 `100...2000`，默认 `1500` |
| `runtime.idleTimeoutSec` | 否 | `daemon` 模式空闲退出秒数，钳制在 `10...3600`，默认 `300` |
| `permissions` | 否 | 插件申请的宿主权限列表（见下表） |
| `preferences` | 否 | 可配置项声明：`key`、`type`（`"string"` 或 `"secret"`）、`title`、`required`、`defaultValue`；`"secret"` 类型存在钥匙串 `plugin.<pluginID>.<key>` 且需声明 `secrets` 权限 |

注意：外部用户插件不允许声明 `legacyProviderID` 或在 `runtime.command` 中使用 `$HOST_HELPERS/`，校验时会直接拒绝。

### 3. 权限清单

所有需要宿主执行的系统动作都会按 `manifest.permissions` 校验，未声明的动作会被拦截并记录警告：

| 权限值 | 设置页显示名 | 覆盖范围 |
| --- | --- | --- |
| `clipboard.write` | 写入剪贴板 | `effect.kind == "copy"` |
| `openURL` | 打开网页链接 | `effect.kind == "openURL"`（仅允许 `http` / `https`） |
| `openFile` | 打开本地文件 | `effect.kind == "openFile"` |
| `revealInFinder` | 在访达中显示 | `effect.kind == "revealInFinder"` |
| `openTerminal` | 在首选终端打开 | `effect.kind == "openInTerminal"` |
| `openApplication` | 启动本机应用 | `effect.kind == "openApplication"` |
| `openAI` | 调用宿主 AI 对话窗口 | `effect.kind == "openAI"`（仅由宿主直连大模型，不向插件暴露 API 密钥） |
| `prefill` | 回填搜索框 | `effect.kind == "prefill"` 及 `homeEntry` 回填关键词 |
| `toast` | 显示通知提示 | `effect.kind == "toast"` 或响应附带 `toast` 文案 |
| `secrets` | 读取插件专用钥匙串密钥 | 注入 `type == "secret"` 的 `preferences` |
| `refresh` | 刷新当前搜索结果 | 动作执行后附带 `refresh: true` |

### 4. NDJSON over stdio 协议（JSON-RPC 2.0）

宿主与插件之间通过标准输入/输出交换**单行 JSON（以 `\n` 分隔）**。插件必须将协议响应写到 `stdout` 并及时 `flush`，日志输出到 `stderr`（宿主截断保留最多 8 KiB）。单条 `stdout` 响应上限为 1 MiB。

启动子进程时宿主注入以下环境变量：

- `DONTSTOOL_HOST_PID`：DontsTool 主进程 PID（便于进程管理类插件排除宿主自身）
- `DONTSTOOL_PLUGIN_ID`：当前插件 ID
- `DONTSTOOL_PLUGIN_DIR`：插件目录绝对路径

#### `search` 请求与响应

请求：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "search",
  "params": {
    "mode": "keyword",
    "keyword": "hello",
    "query": "世界",
    "rawQuery": "hello 世界",
    "frontmostBundleID": "com.apple.finder",
    "preferences": { "greeting": "你好" },
    "hostContext": {
      "hostVersion": "0.4.0",
      "preferredTerminalBundleID": "com.mitchellh.ghostty",
      "aiConfigured": "true",
      "aiFormat": "openai_responses",
      "aiModel": "gpt-4.1-mini"
    }
  }
}
```

`hostContext` 始终包含 `hostVersion`、`aiConfigured`（`"true"` / `"false"`）与 `aiFormat`（`"openai_responses"` / `"gemini"` / `"openai_chat"`）；当用户在「设置 → 工具」选择了固定默认终端时额外包含 `preferredTerminalBundleID`，在「设置 → AI 与翻译」填写了模型名时额外包含 `aiModel`。`hostContext` 仅提供非敏感状态字段，严禁透传 API 密钥。

响应（`items` 最多取前 30 条）：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "notice": null,
    "items": [
      {
        "title": "你好，世界",
        "subtitle": "回车复制结果",
        "score": 1500,
        "canonicalKey": "hello:copy",
        "group": "tool",
        "icon": { "kind": "symbol", "value": "sparkles", "tint": "teal" },
        "badge": { "text": "ONESHOT", "tint": "teal" },
        "actions": [
          {
            "id": "hello.copy",
            "title": "复制问候语",
            "symbol": "doc.on.doc",
            "presentation": "dismissThenRun",
            "effect": {
              "kind": "copy",
              "value": "你好，世界",
              "toast": "已复制",
              "recordUsageKey": "hello:entry"
            }
          }
        ]
      }
    ]
  }
}
```

关键字段枚举：

- `item.group`：可选，默认 `"tool"`，支持 `"tool"`、`"file"`、`"shortcut"`、`"web"`。文件搜索类插件返回 `"file"` 即可进入原生文件分组。
- `item.icon.kind`：`"symbol"`（SF Symbols 名称）、`"glyph"`（短文字）、`"application"`（`.app` 路径）、`"file"`（本地文件路径，取系统文件图标）、`"image"`（包内相对路径图片）。
- `tint`（用于 `icon` 与 `badge`）：`blue`、`sky`、`teal`、`green`、`amber`、`orange`、`red`、`purple`、`indigo`、`gray`。
- `action.presentation`：`"dismissThenRun"`（默认，关闭面板后执行）、`"openWindow"`、`"keepPanelUntilComplete"`（执行完毕再关闭，出错时留在面板）、`"keepPanelOpen"`（保持面板打开，配合 `refresh: true` 可原地刷新）。
- `action.fileAction`：可选，`"reveal"` 或 `"copyPath"`；配合 `group: "file"` 可启用文件行右侧定位按钮和 `⌘⇧C` 复制路径快捷键。

#### `execute` 回调动作

如果动作无需插件二次处理（如直接复制、打开网址或打开路径），在 `action.effect` 里声明宿主动作即可，不会产生二次进程通信。

需要插件自己执行逻辑（如结束进程、调用 AppleScript 切换 Chrome 标签页）时，在动作中设置 `"callback": true` 和可选 `"payload": { ... }`。用户触发后宿主发送 `execute` 请求：

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "execute",
  "params": {
    "actionId": "hello.callback",
    "payload": { "message": "你好，世界" },
    "preferences": { "greeting": "你好" },
    "hostContext": { "hostVersion": "0.4.0", "aiConfigured": "true", "aiFormat": "openai_responses" }
  }
}
```

插件返回：

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "effect": { "kind": "copy", "value": "你好，世界" },
    "toast": "已处理并复制",
    "refresh": true,
    "recordUsageKey": "hello:entry",
    "error": null
  }
}
```

#### 支持的 `effect.kind`

| `kind` | `value` 含义 | 所需权限 |
| --- | --- | --- |
| `none` / `""` | 无动作（可仅搭配 `toast` / `refresh` / `recordUsageKey`） | 无 |
| `copy` | 写入剪贴板的文本 | `clipboard.write` |
| `openURL` | `http://` 或 `https://` 网址 | `openURL` |
| `openFile` | 本地文件或目录绝对路径（支持 `~`） | `openFile` |
| `revealInFinder` | 本地文件或目录绝对路径（支持 `~`） | `revealInFinder` |
| `openInTerminal` | 本地文件或目录绝对路径（支持 `~`，在用户首选终端打开） | `openTerminal` |
| `openApplication` | 本地 `.app` 绝对路径（支持 `~`） | `openApplication` |
| `openAI` | 初始提问文本（也可放在 `options.prompt`）；可选通过 `options` 传入 `title`、`systemPrompt`、`autoSend`（`"true"` / `"false"`，默认非空 prompt 自动发送） | `openAI` |
| `prefill` | 回填到启动器搜索框的文本 | `prefill` |
| `toast` | 显示 Toast 提示文案 | `toast` |

`PluginActionEffectDTO` 支持可选字段 `options: { "<key>": "<value>" }`（字符串键值字典），供 `openAI` 等带扩展参数的宿主动作使用，不影响既有动作的向后兼容。

#### 取消与退出通知（`daemon` 模式）

- **取消请求**：用户继续输入导致旧查询作废时，宿主发送无 `id` 的 JSON-RPC 通知 `{"jsonrpc":"2.0","method":"cancel","params":{"id":1}}`。
- **优雅关闭**：宿主退出、重载或空闲超时时，发送 `{"jsonrpc":"2.0","method":"shutdown","params":{}}` 并关闭 `stdin`；进程应清理任务并退出（超时未退会被 `SIGTERM` / `SIGKILL` 结束）。

### 5. `catalog.json` 发布规范

无论是单插件仓库还是多插件合集仓库，都可以提供一份根目录或 Release 附件中的 `catalog.json`（`schemaVersion: 1`）：

```json
{
  "schemaVersion": 1,
  "sourceName": "我的 DontsTool 插件源",
  "plugins": [
    {
      "id": "com.example.my-plugin",
      "name": "示例插件",
      "summary": "一句话说明功能与关键词",
      "version": "1.0.0",
      "minHostVersion": "0.3.0",
      "downloadURL": "https://github.com/owner/repo/releases/download/v1.0.0/com.example.my-plugin-1.0.0-macos.dontsplugin.zip",
      "subpath": "plugins/com.example.my-plugin",
      "sha256": "<64位小写SHA-256>",
      "official": false
    }
  ]
}
```

打包建议：

- 每个 `.dontsplugin.zip` 解压后根目录直接包含 `manifest.json` 和 `bin/`（也兼容单层顶层目录包裹），确保 `bin/` 下的二进制或脚本具备 `+x` 权限。
- 编译型 Swift 插件建议构建 Universal（`arm64` + `x86_64`）并执行 `codesign --force --sign -`（或使用 Developer ID 签名），避免 Apple Silicon 拒绝执行未签名二进制。
- 发布 GitHub Release 时，同时上传所有 `.dontsplugin.zip` 和 `catalog.json`（`releases/latest/download/catalog.json` 会被安装器优先读取）。

### 6. 参考实现

- 最小 Python 示例插件：[docs/examples/plugins/hello-sidecar/](examples/plugins/hello-sidecar/)
- 官方生产插件集合（含共享 Swift SDK、6 个官方插件、打包脚本与 Release CI）：[CrxusDonts/DontsTool-Plugins](https://github.com/CrxusDonts/DontsTool-Plugins)
