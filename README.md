<p align="center">
  <img src="docs/assets/banner.png" alt="DontsTool" width="100%">
</p>

# DontsTool

这是我们自己日常使用的 macOS 效率小工具，把启动应用、查找文件和常用文本处理放在一个快捷入口里。功能按自己的工作习惯持续改进，也分享给有类似需求的朋友。

使用 Swift 6、AppKit 与 SwiftUI 构建，需要 **macOS 26+**，Universal 安装包支持 Apple Silicon 和 Intel。应用常驻菜单栏，不显示 Dock 图标，默认按 **⌥ Space** 呼出。

## 常用功能

| 功能 | 说明 |
| --- | --- |
| 应用与文件搜索 | 快捷启动应用；输入 `file 文件名` 进行按需 Spotlight 搜索，支持 `⌘↵` 在访达定位、`⌘⇧C` 复制路径 |
| 网址快捷入口 | 自定义层级跳转，支持多环境与子页面（如 `ops avatar management prod`），支持 JSON 批量导入导出 |
| 文本与研发工具 | 输入 `json`、`base64`、`uuid` 等打开独立工具窗口，支持 JSON 格式化与双栏对比、编解码、时间戳与常见哈希 |
| 本地便笺 | 输入 `note` 或 `便笺` 快速检索与新建；独立窗口所见即所得编辑，支持 Markdown 与粘贴图片，数据本地持久化 |
| 划词与独立翻译 | 输入 `tr` 打开翻译窗口，或开启全局右键长按取词；需自行配置 Responses 兼容服务地址、模型与 API 密钥，密钥保存在本机钥匙串 |
| 常用应用联动 | 输入 `gm 问题` 在已安装的 Gemini Mac 中新建对话发送（需辅助功能权限）；输入 `idea 名称` 快速打开 IntelliJ 最近项目 |
| 即时计算与换算 | 输入框直接计算数学算式（如 `1+1`、`sqrt(16)`）或常用单位换算（如 `10 km to mi`），回车快速复制结果 |

选中结果后按 `⌘K` 查看可用操作，如在访达中显示、退出应用、复制链接或路径。

## 安装

> 注：一键安装命令需在仓库公开且 `install.sh` 合入 `main` 后对外可用。

```bash
curl -fsSL https://raw.githubusercontent.com/CrxusDonts/DontsTool/main/install.sh | /bin/bash
```

脚本会从最新稳定版 GitHub Release 下载，自动校验 SHA256 与应用完整性后安装到 `/Applications/DontsTool.app`，无需 `sudo`。若已有旧版，更新前请先正常退出应用。脚本支持指定安装目录与指定版本等参数，详情见 [安装文档](docs/installation.md)。

**手动安装**：

1. 前往 [Releases](https://github.com/CrxusDonts/DontsTool/releases/latest) 下载 `DontsTool-版本号-macos-universal.zip` 及校验文件。
2. 解压后将 `DontsTool.app` 拖入「应用程序」目录。
3. 从「应用程序」打开 DontsTool，按 `⌥ Space` 开始使用。更新时先保存草稿并正常退出旧版，再替换应用。

### 首次打开：本地签名

当前发布包采用 **ad-hoc 本地签名**，未经 Apple 官方公证。签名完整性校验通过不代表已经过 Apple 审查。

如果首次打开被系统拦截，先尝试打开一次，再到 **系统设置 → 隐私与安全性**，找到 DontsTool 对应的提示并选择 **仍要打开**。

## 开始使用

- **快捷唤起**：默认通过 `⌥ Space` 唤起启动器，按 `⌘,` 进入设置调整快捷键（支持修改组合键或双击修饰键）。
- **内容处理**：在空搜索框粘贴文本、链接或 JSON，启动器会自动推荐适用工具并保留原文带入。
- **工具窗口**：从启动器输入 `json`、`base64`、`uuid` 回车可新建独立窗口。窗口可多开、重命名及置顶；工具文本草稿仅保留本次运行，便笺会自动保存。
- **自定义搜索**：可在设置中添加自定义搜索引擎（如公司内网文档库），分配专属快捷词快速跳转。
- **数据与配置**：便笺、网址配置和设置保存在本机；翻译需在设置中配置自己的服务，原文会发送到该服务。

## 开发与构建

项目由 `project.yml` 通过 XcodeGen 管理，`DontsTool.xcodeproj` 不入库。本地开发需要 macOS 26、Xcode 26+ 与 XcodeGen：

```bash
brew install xcodegen
make build
open build/Build/Products/Debug/DontsTool.app
```

常用测试命令：

```bash
make test            # Core 核心单元测试
make test-bridge     # 原生窗口与集成测试
make test-installer  # 安装脚本完整性测试
```

## 详细文档

- [安装与完整性校验](docs/installation.md)
- [网址快捷入口配置说明](docs/website-shortcuts.md)
- [本地便笺使用指南](docs/local-notes.md)
- [划词翻译与配置说明](docs/selection-translation.md)
- [外部应用联动（Gemini / IDEA）](docs/application-actions.md)
- [架构设计与技术决策](docs/architecture.md)
- [版本发布与打包流程](docs/releasing.md)
