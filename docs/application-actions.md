# 应用动作与官方插件外迁说明

自 `v0.3.0` 微内核插件化与 `v0.4.0` 统一多格式大模型引擎落地后，早期的内置应用动作均已演进并由官方插件仓库 [CrxusDonts/DontsTool-Plugins](https://github.com/CrxusDonts/DontsTool-Plugins) 承接，在 **设置 → 插件** 中一键安装管理：

- **AI 快问（`com.donts.quick-ai`）**：取代早期依赖辅助功能控件树的 Gemini Mac 版自动化，直接复用宿主统一大模型引擎与原生流式对话窗口。
- **IntelliJ IDEA 项目（`com.donts.idea-projects`）**：以独立 `daemon` 插件检索并打开 JetBrains 最近项目与本地目录。

## AI 快问（`com.donts.quick-ai`）

早期版本通过 `gm` / `gemini` 借助 macOS 辅助功能控制本机 Gemini Mac 应用；由于第三方桌面应用控件树变动频繁且需要授予辅助功能权限，自 `v0.4.0` 起改为由宿主提供独立的 **模型服务** 多配置引擎与原生流式对话窗口，并由官方插件 `com.donts.quick-ai` 提供快捷入口。

配置与使用方式：

1. 在 DontsTool **设置 → 模型服务** 中添加一套或多套模型配置（支持 `OpenAI Responses`、`Gemini 原生` 与 `OpenAI Chat Completions`），填写接口地址、模型名称与 API 密钥，并可点击「测试连接」验证；可为「默认」「翻译与划词」「AI 快问」分别绑定不同模型（密钥仅存本机钥匙串）。
2. 在 **设置 → 插件** 中安装官方插件 **AI 快问**（`com.donts.quick-ai`，要求宿主 `≥ 0.4.0`），或点击「安装全部推荐插件」。
3. 安装后即刻热加载，支持以下触发方式：
   - `ai 问题` / `ask 问题` / `问 问题`：直接打开原生流式 AI 窗口并发送提问，支持 Markdown 代码块渲染、多轮追问、多开（`⌘N`）与置顶。
   - 单独输入 `ai` 或选择内置场景模板：打开空白窗口或带系统提示词的预设窗口。
   - 在空搜索框按 `⌘V` 粘贴任意文本：可直接选择「问 AI（预填到 AI 窗口）」，先预填草稿再由你确认发送。

权限与隐私：AI 快问不需要 macOS 辅助功能权限；插件仅声明 `openAI` 与 `prefill` 权限，所有模型请求均由宿主进程直接发出，API 密钥不会传入插件进程。

## IntelliJ IDEA 项目（`com.donts.idea-projects`）

自 `v0.3.0` 起，IntelliJ IDEA 最近项目检索与打开功能已拆分为独立外部插件 `com.donts.idea-projects`，托管于官方插件仓库 [CrxusDonts/DontsTool-Plugins](https://github.com/CrxusDonts/DontsTool-Plugins)。

安装与使用方式：

1. 打开 DontsTool **设置 → 插件**，在默认的「DontsTool 官方插件仓库」中找到 **IDEA 项目**（或点击「安装全部推荐插件」）完成安装。
2. 安装后即刻热加载，在启动器中使用原有关键词与交互：
   - `idea`：列出最近打开的 IntelliJ IDEA 项目。
   - `idea kb`：按项目名称和路径片段模糊筛选。
   - `idea ~/路径/项目`：直接打开存在的本地项目目录，不要求先进入最近列表。
   - `⌘K`：在访达中显示、复制路径或在首选终端中打开（复用 **设置 → 通用 → 首选终端** 配置）。

插件以独立 `daemon` 子进程在后台读取 JetBrains 配置目录的 `recentProjects.xml` 并按文件指纹缓存，不扫描全盘、无需 IDEA 插件或辅助功能权限。插件协议、权限说明与更新管理见 [插件使用与开发指南](plugins.md)。
