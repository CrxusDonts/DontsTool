# Knowledge Plugin Implementation Plan

**Goal:** 在 DontsTool 中连接 DontsKb，提供正式文章独立编辑、收集箱与快速收集。
**Architecture:** Core provider/配置契约 + AppKit WKWebView 宿主 + DontsKb 精简 Web surface，沿用现有 API、鉴权和草稿编辑会话。
**Spec:** ../specs/2026-10-18-knowledge-plugin-design.md
**Execution:** 用户明确授权实现；不重复要求阶段许可。按独立文件域并行实现 Core、Web 和 Stitch 参考稿，宿主在本线程实现。DontsTool 无 Git；DontsKb 初始工作区干净；不提交推送部署。

- [x] Core：KnowledgeSurface/OpenRequest/Serving/Origin，KnowledgeProvider，设置和独立知识库分组；先失败测试再实现。
- [x] Web：/tool 专属界面、登录／搜索／编辑／收集复用、协议v1、departure guard；受影响 Vitest 与类型检查，隔离浏览器证据。
- [x] Shell：可信 WKWebView 请求与消息边界、加载错误、原生工具窗口、置顶、关闭与退出协商。
- [x] App/UI：配置页、注册 provider、窗口服务生命周期、原生知识库分组标题。
- [x] Design：Stitch 两屏 HTML 与来源存档，源界面集成以实际代码为准。
- [x] Integration：全量 Swift 测试、Debug／Release、Web 检查和构建、真实 WKWebView 桥与隔离 WebKit 功能流程、全范围复审和修复；桌面手工验收限制单列。
- [x] Docs：更新两个仓库的能力、架构决策、使用与验证结果；明确生产服务更新前置条件。

## Ledger

- 用户已明确完整文章编辑并接受仅知识库插件窗口使用 WebView。替代原 ADR0001 的绝对“无 WebView”约定；启动器与已有本地工具保持原生。
- 插件登录与凭据只在同源知识库 Web 客户端内；原生桥只传搜索结果、标题和窗口事件，不复制 access/refresh token。
- 空查询不连接网络；只在打开插件或显式 kb 关键词搜索时建立桥页面。收集预填不放 URL，不自动保存到服务器。


## 完成记录

- Core 190 测试、真实 WKWebView 桥 5 测试、Web 145 定向单测与 10 条隔离 WebKit E2E 通过；Debug/Release 与 Web 检查/构建通过。
- 完整复审修复退出冻结、模态弹窗逃逸、迟到事务、同源导航、待确认收集与登录边界、保存错误提示等问题。
- 每次明确打开均创建新知识库窗口，不按初始文章请求复用窗口。
- 结果与实际证据边界见 [实现审查](../../reviews/2026-10-18-knowledge-plugin-review.md)。真实账户、物理输入法与原生图钉手工验收未完成；线上部署需要另行授权。

- 后续用户明确授权部署：`8cf2cfa3` 已推送并经 Actions 成功部署，线上 SHA、健康和匿名原生协议探针均验证通过，见 [部署验证](../../reviews/2026-10-18-knowledge-plugin-deployment.md)。
