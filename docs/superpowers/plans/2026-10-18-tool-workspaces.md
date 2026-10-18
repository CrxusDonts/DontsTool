# Tool Workspaces Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans in this session. Track task completion and verification below.

**Goal:** 将七类现有工具迁移到可持续编辑和操作的原生独立窗口，补齐 JSON 转义和结构对比。

**Architecture:** Core 定义工具入口、转换引擎和会话状态；Shell 管理窗口与 NSTextView；SwiftUI 提供工具操作栏和结果。Provider 只返回打开动作，窗口管理器按文档 UUID 管理多窗口会话。

**Tech Stack:** Swift 6, AppKit, SwiftUI, Foundation, CryptoKit, Swift Testing；macOS 26；无新增第三方运行时依赖。

**Spec:** `docs/superpowers/specs/2026-10-18-tool-workspaces-design.md`

## Global Constraints

- 默认内容尺寸 1040×700pt，最小 760×520pt；原生、可缩放、失焦不关闭。
- JSON 每侧 2 MiB UTF-8、最大深度 256；差异列表显示前 1000 条并保留完整数量。
- 本次应用运行中保留草稿，退出后不保存文本；不自动读写剪贴板。
- 维持快捷键、设置开关与 Keychain；应用/文件/网页搜索继续直接动作。
- 当前目录不是 Git 仓库，原地实现并备份涉及旧文件，不初始化 Git。
- 用户已确认方案并明确“开始做”，当前会话直接执行；无需重复请求设计或执行方式许可。

## Review Focus

- JSON 数字超出 Double 精度、指数极大时仍保留精确文本并比较值。
- 新请求不覆盖非空草稿；窗口关闭、编辑和异步结果乱序不能写入旧结果。
- 参数尾部换行和空白不能在启动器解析时消失。
- 原生编辑器程序更新必须可撤销，属性高亮不能打断中文组合输入。
- 启动器退出动画与窗口激活交错时不能抢回旧应用焦点。

## Task 1: 工具转换引擎

Files: `Core/Tools/JSONDocument.swift`, `JSONDiff.swift`, `ToolOperations.swift` under `Sources/DontsToolCore`; `Tests/DontsToolCoreTests/ToolOperationsTests.swift`, `JSONDocumentTests.swift`.

Interfaces: `JSONDocument.parse(_:) throws -> JSONDocument`; `formatted(pretty:) throws -> String`; `JSONDocument.escape(_:) -> String`; `unescape(_:bare:) throws -> String`; `JSONDiff.compare(_:_:) throws -> JSONComparison` with pointer/ranges/counts; `ToolOperations.base64(_:decode:urlSafe:)`, `url(_:decode:form:)`, `timestamps(_:unit:timeZone:now:)`, `uuids(count:uppercase:hyphens:)`.

- [x] Write behavior tests first: format preserves 9007199254740993 and field order; root primitives; duplicate keys error; error line/column; escape one layer; compare object order vs ordered arrays and exact decimal values; pointer `/a~1b/~0`; depth and size bounds.
- [x] Run `make test` and observe missing capabilities; implement a source-ranged iterative JSON parser with numeric lexemes and decimal normalization, cancellable loops and bounded nesting.
- [x] Add fixtures for Base64 UTF-8/URL-safe/padding/malformed input, URL plus/form/invalid bytes, strict date/negative seconds, UUID version and counts. Observe failure then implement functions; preserve old transformer API by delegating JSON to new parser.
- [x] Run complete `make test` and record success.

## Task 2: 工作会话与入口

Files: `Core/Tools/ToolDefinition.swift`, `ToolSession.swift`; modify `Providers/TextToolsProvider.swift`, `TranslationProvider.swift`, `Core/QueryParser.swift`, `Models.swift`; rewrite affected provider tests and add `ToolSessionTests.swift`.

Interfaces: `ToolKind: String, CaseIterable`; `ToolOpenRequest(kind:mode:input:)`; `@MainActor ToolOpening.openTool(_:)`; `ToolSession` observable input/rightInput/output/options, `run()`, `cancel()`, `accept(_:)`, `resolvePending(useNew:)`, result freshness and task version checks. Open actions use new `ActionPresentation.openWindow`.

- [x] Write RED provider tests asserting stable entry title and typed open request, no clipboard side effects, keyword mode, Chinese discovery and disabled providers; parameter parsing preserves trailing spaces/newlines.
- [x] Implement catalog and provider entry generation, retain aliases. Replace obsolete copy-on-Enter tests with opening behavior tests rather than keep both flows.
- [x] Write RED session tests: successful processing, stale results disable copying, invalid input retains drafts, conflicting open requires decision, cancellation/old translation ignored. Implement actual shared session with injected TranslationServicing and background pure operations.
- [x] Full test suite passes.

## Task 3: 原生窗口、编辑器与 UI

Files: `Shell/ToolWindowManager.swift`, `ToolTextEditor.swift`; `UI/Tools/ToolWorkspaceView.swift`, `ToolEditorPane.swift`, `ToolNameEditor.swift`, `ToolTheme.swift`; modify `App/AppController.swift`, `Shell/LauncherPanelController.swift`, `UI/DesignSystem/Theme.swift`.

Interfaces: `ToolWindowManager: ToolOpening` retains a controller/session per document UUID; `ToolTextEditor` binds text, optional selection range, JSON styling, wrapping and read-only state. Views consume ToolSession and callbacks for clipboard/settings/URL.

- [x] Implement standard resizable windows and explicit focus handoff; test catalog/session boundaries before GUI integration, verify native focus through real window activation.
- [x] Implement NSTextView bridge with scroll/ruler, find bar, native undo, disabled substitutions, IME-safe syntax attributes, source selection navigation.
- [x] Implement JSON edit/diff views and diff selection; utility views for Base64/URL/hash, timestamp structured result, UUID row copying, translation settings/cancellation.
- [x] Apply the warm linen/graphite ToolTheme and controlled 120–180ms state transitions honoring reduced motion; avoid animating document text edits. Build and inspect actual GUI at default and minimum sizes.

## Task 4: Stitch HTML 与整体验证

Files: `design/tool-workspaces/` (initial draft), `design/tool-workspaces-v2/` (final direction), corresponding `.stitch/` source exports and metadata, README and architecture.

- [x] Generate JSON diff/Base64/UUID reference screens using existing Stitch design system; archive original HTML and asset metadata, export browsable HTML links under design/tool-workspaces.
- [x] Self-review generated screens against spec; remove unsupported design suggestions from the integrated product. Preserve source provenance; mock HTML is not runtime evidence.
- [x] Full `make test`, Debug and Release build. Run application, exercise independent JSON windows, JSON format/diff, Base64 encode/decode, result transfer and undo, named draft reopening, focus and resizing. Record unexercised GUI paths and physical/IME checks separately below.
- [x] Fresh reviewer inspects all touched sources for correctness and spec coverage; address significant issues with regression tests.
- [x] Update README/architecture and final report with exact test count, exported design paths and real validation limits. Do not publish or upload release assets.

## Execution ledger

- Start: user approved written spec and requested implementation plus autonomous Stitch/HTML design work. Native execution selected to keep shared interfaces consistent. Current directory has no Git metadata; no branch or commit steps apply.
- UI review steering: user rejected the first white native prototype and asked for web style research followed by new design drafts. Pause visual integration; preserve implementation and tests. New drafts go under `design/tool-workspaces-v2/`, with a separate Stitch project so the old design system stays intact.
- Core evidence: baseline passed; JSON precision, order, escape, diff and depth tests passed after splitting parser recursion frames. First integrated suite ran 119 tests with one outdated trailing-space expectation in QueryParserTests; this expectation must be updated to the approved preservation behavior before final verification. Native format and result-to-input undo were exercised. JSON diff GUI paste automation needs fresh targeting: a two-pane paste sequence appended both samples to the left; the parser correctly reported extra content. No completion claim yet.

- Multi-window ruling: latest user request requires independent same-tool documents, editable window/side names, new/duplicate/switch/reopen. User explicitly authorized implementation immediately after design without a review stop. Update the old singleton policy; Core document store and engine audit proceed independently under dispatching-parallel-agents while native window/UI integration stays in the parent.
- Added deliverables: ToolDocument/ToolDocumentStore + isolated draft tests; NSWindow title binding, document actions and standard Window menu; multi-window Stitch exports and HTML previews.

- Final interaction correction: user rejects added window management UI. Keep launcher → tool → NEW independent window every time; remove new/duplicate/window-list controls from tool UI, preserve title rename and standard macOS window switching. No extra review stage requested.


## Final verification — 2026-10-18

- Final interaction: launcher entry always creates a new independent window. Native smoke test clicked JSON from the launcher while JSON 1 already existed and received JSON 2; launcher hid and focus moved to the new window. No custom new/duplicate/window-list controls remain in the tool UI. Window title is editable.
- Core regression suite: `make test`, 158 tests in 25 suites, passed. Covers exact JSON numeric/Unicode semantics, nested/large input bounds, diff counts/ranges, utilities, provider opening behavior, draft isolation, cancellation and compound undo.
- Debug build passed; Release build passed using `xcodebuild -project DontsTool.xcodeproj -scheme DontsTool -configuration Release -derivedDataPath /tmp/dontstool-workspaces-release build`. No release package was published or installed.
- Native checks: warm/light and graphite/dark appearance; large-integer JSON format; edit/compare draft separation; `/id` modification result; Base64 hello encoding/decoding; exchange undo/redo restores both content and direction; title rename; close/reopen preserves title, mode and both comparison drafts; resized JSON comparison window keeps controls accessible.
- Review regressions addressed: exact-byte Unicode freshness, compound mode/side-name undo, transfer into comparison side restores prior text and mode. Final read-only review reported no actionable P0/P1/P2 findings.
- Interactive regression: hiding a native editor by disabling editability caused its shared undo entry to be consumed without changing its text. Reproduced before the fix; inactive editors now stay hidden and relinquish focus while retaining editability for native undo. Repeated the same cross-mode undo/redo flow successfully afterward.
- HTML: final `simple-linen.html` / `simple-graphite.html` are the index defaults. Inline scripts syntax-checked; local assets/dependencies checked. Original Stitch PNGs are provenance, not screenshots of the corrected exports. Browser-rendered local HTML was not verified because the browser tool rejected file URLs; no workaround was used.
- Limits: Chinese text passed through native paste, but physical Chinese IME composition was not verified. Real translation API requests were not sent; translation behavior uses injected mocks in tests. GUI smoke testing focused on JSON and Base64; other utility engines have unit coverage. Drafts remain memory-only for the current process.


## Comprehensive review follow-up

用户要求从架构、代码、交互和功能全面复审并修复。确认并修复 6 类 P2 问题，新增回归后完整套件为 170 tests / 26 suites，Debug 和 Release 构建通过。原生补测覆盖此前未完整操作的 UUID、URL、时间戳、哈希和未配置翻译，以及 JSON CR 行号与失败重跑过期提示。详见 [全面审查记录](../../reviews/2026-10-18-tool-workspaces-review.md)。此前 158 项验证及 GUI 覆盖限制为当时快照，以本节和审查记录为最新结果。


## Window pinning follow-up

用户提出窗口置顶需求。每个 ToolDocument 独立持有 isPinned，原生窗口订阅该状态并在 floating / normal 层级间切换；失焦不隐藏，其他窗口不受影响。图钉显示“置顶／已置顶”，再点一次取消。本次运行内关闭重开保留，新窗口默认关闭。回归验证状态隔离、结果新鲜度与草稿恢复；原生验证开关、新窗口默认关闭、关闭重开和取消。完整 make test 为 171 tests / 26 suites，Release 构建通过。


## In-place editing follow-up

用户确认“JSON、Base64、URL 单编辑区原地操作，JSON 对比才双栏，哈希和时间戳紧凑展示结果”。ToolDraftEditor.run 只在上述文本转换模式下提交有效结果；任务与版本检查、2 MiB 可编辑结果上限都在替换前执行。成功替换为一次原生共享 UndoManager 记录，错误或取消保留原文，操作不自动切换编码方向。JSON／编码工具改为直接动作按钮，⌘↩ 重复当前动作，复制直接取当前文档文本。

新增 7 项 Core 回归，RED 先观察到缺少 editor.run 以及超限结果覆盖原文，GREEN 通过；完整套件 **178 tests / 27 suites** 通过。新上下文审查指出输出膨胀超出下一次输入上限的问题，已在共同提交边界修复，复审无新增可执行 P0–P2。Debug 和 Release 构建通过。

原生验证：大整数／中文 JSON 原地格式化、一次撤销与重做、连续压缩／转义／去转义、⌘↩ 与错误保留原文、送到对比侧及跨模式撤销；Base64 编码解码与撤销重做；哈希 compact card；时间戳三行结果、单行复制入口及缩小到最小尺寸后的布局。由原生窗口显式控制默认尺寸并保留既定 contentMinSize，避免 NSHostingView 内容拟合改变窗口约束；最终 JSON 截图为 2080×1464 像素（2× 显示下的 1040×700pt 内容及标题栏）。

文档已同步最新单区交互；此前 input/result HTML 是早期探索稿，不能用其双栏布局代表当前实现。保留置顶、标题、多窗口及内存草稿策略。没有验证物理中文 IME；没有发出真实翻译请求。

验证日志：`/tmp/dontstool-inplace-final-tests.log`、`/tmp/dontstool-inplace-final-release.log`、`/tmp/dontstool-inplace-window-size.log`。
