# 本地便笺实现计划

**Goal:** 原生启动器集成离线、自动保存、支持图片的所见即所得 Markdown 便笺。
**Architecture:** Swift 持久化库与原生窗口；本地 Tiptap 编辑器通过有界 WKWebView 消息协议沟通；正文 JSON 与附件按稳定 UUID 隔离。
**Tech Stack:** Swift 6、AppKit、SwiftUI、WebKit、Tiptap 3、esbuild、Node 测试。
**Spec:** ../specs/2026-11-17-local-notes-design.md

## Global Constraints

- 复用当前 UI 风格，默认单栏所见即所得；不依赖原图片路径。
- Markdown 为交换格式，正文 JSON 为权威；只在本机处理，不自动联网。
- 保存失败保留草稿，关闭与退出必须同步最新正文；仅一篇一个窗口。
- 现有配置与快捷词不得静默损坏或被抢占；初期仅本地验收；用户于 2026-11-17 补充授权全部提交推送，本轮仍不创建 Release。

## Review Focus

- 粘贴／拖入后移动或删除原图，重开便笺仍显示；撤销插图与跨便笺复制不丢图。
- 关闭、退出、重载、快速输入时的保存顺序和失败状态；删除后旧保存不能重建文档。
- 损坏记录、未来版本、附件路径穿越／软链接、超大图片与外部资源。
- 中文组词、编辑选择、Markdown 源码切换及格式／图片导入时焦点保持。
- 标题变化、多窗口同一篇去重、置顶、查找与快捷词冲突。

## Tasks

- [x] 1. 持久化与附件：LocalNoteContent/Record/Asset、LocalNoteStore，原子写入、检索、最近删除恢复、附件归属与带图导出。先运行失败用例再实现，单独 Core 测试。
- [x] 2. 离线编辑器：Tiptap 所见即所得、Markdown、工具栏、原生消息协议、图片导入与相对引用、源码切换、主题；锁定依赖、打包资源、行为测试。
- [x] 3. 原生桥与窗口：scheme 文件边界、消息校验、剪贴板图片／文件处理、自动保存会话、窗口关闭／退出保护、命名置顶导出与恢复；WebKit 真实集成测试。
- [x] 4. 启动器与构建：note provider／设置开关、检索与现有快捷词边界、资源打包和文档；Stitch 导出、原生深浅色渲染、完整必要回归与本地安装。

## API Contract

Swift Core: `LocalNoteContent(json:markdown:plainText:)` with `.empty`; `LocalNoteRecord` has `id:UUID`, `title`, `titleIsAutomatic`, `isPinned`, `createdAt`, `updatedAt`, `content`; `LocalNoteAsset(relativePath:mimeType:)` metadata. `@MainActor LocalNoteStore(rootURL:)` publishes `notes`, `trashedNotes`, `loadError`; throwing sync `create()`, `updateContent(_:content:)`, `rename(_:title:)`, `setPinned(_:pinned:)`, `trash(_:)`, `restore(_:)`, `importImage(_:for:)`, `importImageFile(_:for:)`, `copyImage(from:relativePath:to:)`, `assetURL(for:relativePath:)`, `exportMarkdown(_:content:to:)`; `note(_:)` and `search(_:limit:)`. Methods return updated record or asset where appropriate. RootURL is app support by default, tests always use isolated directories.

Web: native posts `window.dontsNote.load({noteID,content:{json,markdown,plainText},appearance})`; API `snapshot()` returns same content object, `insertImage({token,src,alt})`, `resolvePaste({token,handled,images?,error?})`, `setAppearance('dark'|'light')`, `focus()`. JS messages via `window.webkit.messageHandlers.dontsNote.postMessage`: `ready`; `change` with monotonic `revision` and `content`; `paste` with token and fallback data handled by JS; `importImage` with token, base64, MIME; `copyImage` with token, sourceNoteID, relativePath; `openLink` with URL; `error` with user-safe message. Relative stored image src is `assets/<uuid>.<ext>`; runtime editor origin is `donts-note://<noteUUID>/index.html`. Resource names `index.html`, `editor.js`, `editor.css`.

## 本地验收结果

- Core：435 项全量回归通过；中文路由后另跑 Provider/Settings 18 项通过，覆盖已有 `note` 配置和重启后便笺访问。
- 编辑器最终 21 项通过；真实原生/WebKit 全量 134 项通过；浏览器图片 HTML 与像素共存路径补齐后，便笺最终 9 项集成通过。
- 真实 WKWebView 深浅色截图已查看，窗口去重、多窗口、最新输入关闭保存、磁盘失败保留草稿、无效源码状态、剪贴板图片、离线恢复和 scheme 边界均有集成验证。
- 独立审查发现的快捷词冲突、旧 autosave 清除错误、冻结失败未解冻、图片 alt 覆盖问题已修复并复查。
- Universal Release 配置本地构建成功；稳定本机签名、双架构、安装文件与生成编辑器资源一致性通过。已安装 `/Applications/DontsTool.app`，本地 0.2.6 build 11；构建副本已清除。
- 界面控制连接连续超时，未完成安装后通过系统键鼠的手动点击验收；未把该步骤记为通过。没有要求用户反复操作。
- 本地验收阶段未提交、未推送、未创建 Release；用户随后授权全部提交推送，按最终验收结果合入 main。

日志与本地证据位于忽略目录 `build/local-notes/`：`core-regression.log`、`provider-alias-green.log`、`editor-tests-final.log`、`bridge-regression.log`、`native-tests-final.log`、`release-build-final.log`、`installed-verification.json`、`editor-preview-light.png` 和 `editor-preview-dark.png`。

## 后续知识库开关与交付

用户补充要求可关闭知识库功能。复用既有 provider 启用设置，在「设置 → 知识库」顶部显示开关，与「工具」页同步；关闭时隐藏三个入口、停止并释放后台搜索客户端、拒绝旧搜索结果动作和新窗口。已有编辑窗口保留，继续沿用其保存／退出保护。快速关闭再开启也不会恢复先前等待中的搜索。设置持久化保留服务配置。

已新增 Core 行为和原生开关测试，完成本机 Universal 构建和稳定签名安装（0.2.6 build 12）。提交推送前执行编辑器、Core 与原生完整回归，并复查全部改动；远端 CI 结果作为交付的最后检查。

最终提交前回归：439 项 Core、136 项原生/WebKit、21 项编辑器测试全部通过；离线 bundle 重新构建后与本机 build 12 的资源字节一致。复查未发现 P1/P2 阻塞。
