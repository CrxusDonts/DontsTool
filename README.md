<p align="center">
  <img src="docs/assets/banner.png" alt="DontsTool" width="100%">
</p>

# DontsTool

DontsTool 是一个原生 macOS 菜单栏效率启动器。`v0.3.0` 起采用微内核宿主加进程外 Sidecar 插件的架构：主程序保留应用启动、文本工作台、便笺、翻译与同步等核心热路径，文件搜索、Chrome、IDEA 项目、终端与访达、结束进程等扩展能力迁至官方插件仓库，按需在设置页安装和更新。

使用 Swift 6、AppKit 和 SwiftUI 构建，要求 **macOS 26+**，发布包为 Universal（支持 Apple Silicon 与 Intel）。应用常驻菜单栏，不显示 Dock 图标，默认按 `⌥ Space` 呼出。

## 微内核内置能力

| 功能 | 说明 |
| --- | --- |
| 应用启动 | 按英文名、中文名、全拼和首字母搜索本机应用；通过 FSEvents 监听应用目录变更，支持按最近打开、频率或名称排序 |
| 即时计算与换算 | 在搜索框直接输入算式（如 `(128 + 64) * 3`、`sqrt(16)`）或单位换算（如 `10 km to mi`），回车复制结果 |
| 快速打开 | 直接识别 `http(s)://`、`www.`、`~/`、绝对路径与 `file://`，回车打开，按 `⌘K` 可在默认终端打开或访达定位 |
| 网址快捷入口 | 自定义层级跳转，支持多环境（如 `prod` / `test`）与子页面，提供表单编辑和 JSON 批量导入导出 |
| 网页搜索 | 自定义搜索引擎快捷词；普通查询无本地结果时回退到默认搜索引擎 |
| 文本工具工作台 | 输入 `json`、`b64`、`url`、`ts`、`uuid`、`md5`、`sha256` 打开独立工作窗口，支持多开、置顶、JSON 折叠与双栏对比 |
| 翻译与长按划词 | 输入 `tr` 打开翻译窗口，或在设置中开启全局鼠标右键长按划词；对接 OpenAI Responses 兼容接口，密钥存本机钥匙串 |
| 本地离线便笺 | 输入 `note` 或 `便笺` 检索与新建，支持离线 Tiptap 所见即所得和 Markdown 编辑、粘贴图片、置顶与回收站 |
| Gemini 提问 | 输入 `gm 问题` 在已安装的 Gemini Mac 版中新建对话并发送（自动发送需辅助功能权限） |
| 使用指南 | 输入 `help` 或 `?` 打开内置功能与快捷键速查，支持点击示例直接填入启动器 |
| Cloudflare 多端同步与备份 | 可选部署自建 Cloudflare Worker（Durable Object + R2）跨 Mac 增量同步，也支持本地 `.zip` 完整备份与恢复 |
| 应用内更新 | 接入 Sparkle 2.10.1 与 Ed25519 签名校验，通过菜单栏「检查更新」升级 |

选中结果后按 `⌘K` 打开更多操作面板，按 `⌘↵` 执行次操作；在空搜索框粘贴文本、链接或 JSON，启动器会自动进入内容模式推荐对应工具。

## 官方插件仓库与插件生态

外部插件以独立子进程通过 NDJSON over stdio（JSON-RPC 2.0）与宿主通信，互不阻塞启动器热路径，支持热重载与独立启停。

DontsTool 在 **设置 → 插件** 中默认内置官方插件仓库 [CrxusDonts/DontsTool-Plugins](https://github.com/CrxusDonts/DontsTool-Plugins)，你可以点击「安装全部推荐插件」一键装齐，也可以按需单独安装：

| 插件 ID | 名称 | 触发关键词 | 说明 |
| --- | --- | --- | --- |
| `com.donts.kill-process` | 结束进程 | `kill`、`kp`、`进程` | 按名称、PID、命令行或 `:端口` 查找并结束进程，支持优雅退出与强杀 |
| `com.donts.idea-projects` | IDEA 项目 | `idea` | 读取 IntelliJ IDEA 最近项目列表，支持模糊筛选与直接输入本地目录路径打开 |
| `com.donts.file-search` | 文件搜索 | `file` | 在用户主目录内按需调用 Spotlight 检索本地文件，支持访达定位与 `⌘⇧C` 复制路径 |
| `com.donts.chrome` | Google Chrome | `chrome`、`ch`、`tab`、`tabs`、`bm`、`书签`、`标签页` | 搜索、切换与关闭已打开标签页，同时检索多 Profile 书签与浏览历史 |
| `com.donts.terminal-finder` | 终端与访达 | `tf`、`ft`、`term`、`终端` | 在访达与 Ghostty、Warp、iTerm2、系统终端等终端应用之间双向跳转当前目录 |
| `com.example.hello-sidecar` | Hello Sidecar 示例 | `hello` | 无外部依赖的 Python 示例插件，演示多语言 Sidecar 协议与回调动作 |

除了官方源，**设置 → 插件** 也支持添加自定义 GitHub 仓库（输入 `owner/repo`、仓库链接或 `catalog.json` HTTPS 地址，兼容单插件仓与多插件合集仓）。安装与更新前会校验宿主版本与 SHA-256，并在弹窗中列出插件申请的全部权限以及跨源同名冲突提示，确认后才落盘并热重载。详见 [插件使用与开发指南](docs/plugins.md)。

## 安装与升级

在终端运行安装脚本，无需登录 GitHub 或使用 `sudo`：

```bash
curl -fsSL https://raw.githubusercontent.com/CrxusDonts/DontsTool/main/install.sh | /bin/bash
```

脚本会拉取最新稳定版 Release，校验 SHA-256、Developer ID 签名与 Apple 公证票据后安装到 `/Applications/DontsTool.app`。指定目录或指定版本参数见 [安装与完整性校验](docs/installation.md)。

手动安装：

1. 前往 [Releases](https://github.com/CrxusDonts/DontsTool/releases/latest) 下载 `DontsTool-版本号-macos-universal.zip`。
2. 解压并将 `DontsTool.app` 拖入「应用程序」目录。
3. 打开应用后按 `⌥ Space` 呼出启动器，前往 **设置 → 插件** 安装需要的官方插件。

已安装旧版的用户可以直接在菜单栏选择「检查更新」升级到最新稳定版。

### 签名与公证说明

自 `0.2.10` 起，正式发布包使用 Apple Developer ID（Team ID：`Q2K3CAKGG2`）签名、开启 Hardened Runtime 并经 Apple 公证及离线钉票，下载后可直接通过系统 Gatekeeper 打开。

如果使用 `0.2.9` 或更早的历史版本（采用 ad-hoc 本地签名），首次打开被系统拦截时，先尝试打开一次，再到 **系统设置 → 隐私与安全性** 选择「仍要打开」。

## 权限与隐私边界

- 无遥测，不上报使用数据。
- 不在后台监听剪贴板；仅在用户主动复制/粘贴或触发右键长按划词翻译时访问剪贴板。
- 翻译 API 密钥、Cloudflare 同步密钥及插件私密配置存放在 macOS 登录钥匙串，不写入 `UserDefaults`、日志或本地备份包。
- 网络请求仅在主动执行网页搜索、翻译、检查应用更新、拉取/安装插件或启用自建云同步时发生。
- 系统权限按需申请：组合键热键与双击修饰键不需要辅助功能权限；仅 Gemini 自动发送与右键长按划词翻译需要「辅助功能」，Chrome / 终端访达插件需要「自动化」，文件搜索插件在受保护目录可按需授权「完全磁盘访问」。
- 外部插件运行前强制校验 `manifest.json` 权限声明，未声明的宿主动作会被拦截。

## 开发与构建

工程配置以 `project.yml` 为源，`DontsTool.xcodeproj` 由 XcodeGen 生成且不入库。本地开发需要 macOS 26、Xcode 26+ 和 XcodeGen：

```bash
brew install xcodegen
make build
open build/Build/Products/Debug/DontsTool.app
```

常用验证命令：

```bash
make test            # Core 核心单元测试
make test-bridge     # 原生窗口、系统事件与 WebKit 桥接测试
make test-editor     # 离线便笺编辑器测试并重新生成资源
make test-updater    # 解析依赖并测试更新源签名脚本
make test-installer  # 安装脚本完整性与回滚测试
```

## 详细文档

- [插件使用与开发指南](docs/plugins.md)
- [安装与完整性校验](docs/installation.md)
- [网址快捷入口配置说明](docs/website-shortcuts.md)
- [本地便笺使用指南](docs/local-notes.md)
- [划词翻译与配置说明](docs/selection-translation.md)
- [应用动作（Gemini 与外迁说明）](docs/application-actions.md)
- [架构总览](docs/architecture.md)
- [ADR 架构决策记录](docs/adr/)
- [版本发布与打包流程](docs/releasing.md)
