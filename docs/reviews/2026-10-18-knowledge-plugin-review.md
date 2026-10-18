# 知识库插件实现、复审与验证

2026-10-18，本地实现完成。后续已获用户授权并完成生产部署，见 [部署验证](2026-10-18-knowledge-plugin-deployment.md)。以下未部署描述保留初始本地交付时的边界。DontsTool 无 Git；DontsKb 改动保留工作区，未提交、推送、部署。未读写真实知识库内容。参考稿位于 `design/knowledge-plugin/index.html`，是独立 Stitch HTML 导出；运行时来自 Swift 宿主与 DontsKb React 源码。

## 已实现

- 启动器新增知识库、快速收集、收集箱入口；`kb 关键词` 搜索正式文章，`collect 文字` 传入待确认文字，`inbox` 打开整理工作台。旧偏好一次性迁移启用新 provider，后续显式关闭不会被再次开启。
- 每次打开独立原生窗口，支持多文章、同步文章标题、置顶、加载/失败/重连。启动器和本地文本工具保持原生。
- Web `/tool` 精简外壳承载现有 DocumentPage、CaptureComposer 与 CaptureWorkbench。正文、标题、自动保存、本地草稿、上传、版本与修订冲突继续归知识库模块。
- 配置只保存 HTTPS 来源；本地开发接受 HTTP loopback。WebView 共用默认数据存储，登录在页面内进行。原生不接收密码、JWT 或刷新凭据。
- 收集原文通过 RPC 传递，不在 URL 中，也不自动创建服务器记录。已有草稿仅在明确追加时修改。未追加队列在关闭或退出登录前询问放弃。

## 审查发现与修复

1. **P1，退出检查后仍可编辑。** 多窗口退出中，已确认页面以协议锁定；原生窗口遮罩且清空 first responder，阻止新窗口打开。任一拒绝则全部恢复。
2. **P1，模态收集框逃逸祖先 inert。** 对已有 `dialog[open]` 本身设置 inert，保留此前属性；新建的离开确认框仍可交互。成功锁定持续到恢复；拒绝还原。
3. **P2，超时的旧关闭请求迟到后再次锁定。** `resumeInteraction` 递增事务 generation；过期 guard 不能锁定页面或解冻后续事务。并行调用合并，原生单窗口握手也防重入。
4. **P2，同源普通链接带出插件后无法关闭。** 原生导航仅接受 `/tool` 与对应登录页；普通链接交给浏览器。重试缺失 URL 或非插件 URL 时回到初始插件入口。
5. **P2，窗口按初始文章错误复用。** 取消复用，明确打开均新建，避免文章内导航后激活错误内容。
6. **P2，收集待确认文字退出登录时丢失。** 注册共享 logout guard，拒绝后保留队列；原生在未收到预填接受回执前也保留文字。
7. **P2，收集箱暴露不可用 Agent 操作。** 精简插件内不展示依赖完整 AgentPanel 的操作。
8. **P2，保存风险只在 hover 展示。** 离线、冲突和本地存储错误直接以 `role=status` 显示描述，区分本地已持久化与仍需保持窗口打开的状态。
9. **P2，快速 provider 的连接/登录提示未发布。** 搜索协调器收集 fast notice，慢查询优先使用自己的 notice；入口型查询清除过期知识库提示。
10. **WebKit 代理回调签名。** 使用 SDK 要求的 `@MainActor @Sendable` 完整签名，消除“nearly matches optional requirement”警告；用真实 WKWebView 导航拒绝回归验证代理生效。

最终独立复审未发现新的必须修复项；桥与协议测试再次通过 11 项。

## 当前验证

| 范围 | 执行结果 |
| --- | --- |
| `make test` | 190 项 Core 测试，29 suites，通过 |
| `DontsToolBridgeTests` | 5 项真实 WKWebView 集成测试，通过 |
| `make build` | Debug 构建通过 |
| `xcodebuild -project DontsTool.xcodeproj -scheme DontsTool -configuration Release -derivedDataPath build build` | Release 构建通过 |
| Web 定向 Vitest | 6 个文件，145 项，通过 |
| 隔离 WebKit E2E | 10 条，通过；全部 `/api/**` 使用虚构内存回执拦截 |
| Web `check` / `build` / 定向 lint / `git diff --check` | 通过；构建保留原有大 chunk 提示 |
| Stitch HTML 导出 | 两屏、离线导航、外部请求/JS 错误/坏图均为 0 |

桥集成测试覆盖 ready/标题、RPC 参数编码、关闭否决、实际执行的 iframe 消息拒绝、协议版本不匹配、普通同源页面导航拒绝与重载、首次 URL 为 nil 的连接失败重试。测试命令：

```bash
xcodebuild -project DontsTool.xcodeproj -scheme DontsToolBridgeTests \
  -destination 'platform=macOS' -derivedDataPath /tmp/dontstool-bridge-tests test
```

Web 定向命令（在 DontsKb 仓库）：

```bash
corepack pnpm --filter @dontskb/web test tests/unit/features/tool-plugin \
  tests/unit/features/captures/capture-composer.test.tsx \
  tests/unit/features/captures/capture-mobile-workbench.test.tsx \
  tests/unit/features/documents/document-page.test.tsx tests/unit/app/app.test.tsx
E2E_BASE_URL=http://127.0.0.1:4187 E2E_BROWSER=webkit \
  corepack pnpm --filter @dontskb/web test:e2e tests/e2e/tool-plugin.spec.ts
corepack pnpm --filter @dontskb/web check
corepack pnpm --filter @dontskb/web build
```

E2E 端口为本次隔离 Vite 服务，已停止；重跑需按仓库测试说明启动自己的测试服务。验证日志：`/tmp/dontstool-knowledge-final-tests.log`、`/tmp/dontstool-bridge-tests.log`、`/tmp/dontstool-knowledge-final-debug.log`、`/tmp/dontstool-knowledge-final-release.log`、`/tmp/dontskb-tool-plugin-final-build.log`。

## 证据边界

真实 WKWebView 测试验证原生桥；WebKit E2E 验证实际 React 编辑器与收集功能，两者均使用隔离本地数据。原生桌面自动化获取 DontsTool 连续超时，本次未完成图钉、多窗口真实账户共用登录及物理中文输入法的手工验收。不要把隔离 WebKit 证据表述为完整真实账户端到端验收。

线上知识库仍须另行授权发布 `/tool` 路由及协议。随后在 DontsTool 设置 → 知识库填写来源，在插件窗口登录。当前任务没有更新生产 Web 服务，未将生成的 HTML 作为运行时编辑器。
