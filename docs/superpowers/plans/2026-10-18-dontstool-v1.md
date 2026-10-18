# DontsTool V1 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个原生 macOS 效率启动器：全局热键呼出、搜索并启动应用/文件、文本小工具、网页搜索与翻译，全部行为可由键盘完成。

**Architecture:** 单进程菜单栏 App。`DontsToolCore` 是静态库，承载模型、搜索聚合、索引、Provider 与系统服务协议；`DontsTool` 是 App target，承载生命周期、AppKit 面板、菜单栏和设置 UI。所有 Provider 实现同一个 `ToolProvider` 协议，`SearchCoordinator` 只依赖协议做两阶段聚合。

**Tech Stack:** Swift 6 / AppKit / SwiftUI（设置与翻译宿主）/ Carbon 热键 / Translation / CryptoKit / XcodeGen 2.46 / Xcode 27.1 / macOS 26+ / Swift Testing。

**Spec:** [V1 详细设计](../specs/2026-10-18-dontstool-design.md)

## 实现记录（2026-10-18，M1–M3 主体已完成）

以下偏差已落地，后续任务以代码与 `docs/superpowers/specs/2026-10-18-dontstool-design.md` 为准，不要照抄下文旧步骤：

0. **性能实测（2026-10-18，M4 Task 17）**：冷启动到可呼出 53.5ms（预算 1.5s）；热键到面板可见 1.5ms 热 / 28.5ms 首次（预算 100ms p95）；输入到快速结果 1.4–50ms（预算 50ms p95）；文件结果用户可见 ≤300ms（300ms 超时 + 部分结果提示），原始 mdfind 限定用户目录后 p50≈306ms、冷启动 547–669ms；模糊评分基准 5000 候选 × 1000 查询 p50≈20.1ms/查询；常驻内存 ≈112MB（预算 150MB）；空闲 CPU 0.0%（预算 0.5%）。埋点见 `DontsToolCore/Core/Performance.swift`（signpost + 日志）。
1. **界面框架**：面板与设置内容改为 SwiftUI（`Sources/DontsTool/UI/`），AppKit 仅保留 NSPanel/热键/搜索框键盘/菜单栏薄壳；设计令牌层 `UI/DesignSystem`（Theme/Metrics/Motion）对齐 `design/` 设计稿。旧 `ResultListViewController`、`IconLoader` 已删除。
2. **面板状态层**：新增 `DontsToolCore/Core/LauncherPanelModel.swift`（分组、键盘选择、状态栏、Toast），壳层 `LauncherPanelController` 只负责窗口与动效。
3. **图标模型**：`ItemIcon` 扩展为 `symbol(name:tint:)` 与 `glyph(text:tint:)`，`SearchItem` 新增 `keyword` 行尾标签。
4. **翻译后端**：放弃 Apple Translation（首用下载确认模态挂在隐形宿主窗口导致会话永久等待），改为 OpenAI Responses 兼容 API（`RemoteTranslationService` + `HTTPClient` + `SecretStore` 钥匙串）；未配置时显示「配置翻译 API」+ 网页兜底。
5. **设置窗口**：`SettingsWindowController` + `SettingsRootView`（通用/搜索/工具/翻译/索引/关于），含热键录制、`SMAppService` 登录项、翻译 API 配置；菜单栏新增「设置…」。
6. Task 13 的 `FileSearchService` 使用 hits 携带评分、移除存在性检查、`ProcessCommandRunner` 用 readabilityHandler 持续排空输出；Task 14/15 的旧代码块仅作历史参考。

## Global Constraints

- 最低系统 macOS 26.0；Swift 6 语言模式，严格并发检查。
- 运行时零第三方依赖；XcodeGen 只用于生成工程，不进入 App。
- 界面简体中文；代码标识符英文。
- 全局热键使用 Carbon `RegisterEventHotKey`，不申请辅助功能权限。
- 应用自身不发起后台网络请求；网页搜索交给默认浏览器，翻译由系统框架处理。
- 不监听剪贴板；只在用户显式执行文本工具或翻译时读取。
- 文件搜索只调用 `/usr/bin/mdfind`，参数数组传递，不经过 shell。
- 性能预算：热键到面板可见 ≤100ms p95；本地快速结果 ≤50ms p95；文件结果 ≤300ms p95；常驻内存 ≤150MB；空闲 CPU ≤0.5%；冷启动可呼出 ≤1.5s。
- `DontsToolCore` 中除明确标注的 `Task.detached` / 后台进程外，其余类型默认 `@MainActor`。
- 文档是源：行为变化同步 Spec，模块边界变化同步 Architecture，新决策补 ADR。
- **提交策略：仓库尚未初始化 git，用户未要求提交。本计划所有任务不含 git commit；以 `make test` / `make app` 通过为完成标准。只有用户明确要求时才初始化仓库并提交。**

---

## 文件结构

```text
DontsTool/
├── project.yml
├── Makefile
├── .gitignore
├── Resources/
│   └── Info.plist
├── Sources/
│   ├── DontsTool/
│   │   ├── DontsToolMain.swift
│   │   ├── App/
│   │   │   ├── AppDelegate.swift
│   │   │   ├── AppController.swift
│   │   │   └── MenuBarController.swift
│   │   ├── Shell/
│   │   │   ├── HotKeyManager.swift
│   │   │   ├── LauncherPanel.swift
│   │   │   ├── LauncherPanelController.swift
│   │   │   ├── SearchField.swift
│   │   │   ├── ResultListViewController.swift
│   │   │   ├── IconLoader.swift
│   │   │   └── ToastPresenter.swift
│   │   └── Settings/
│   │       ├── SettingsWindowController.swift
│   │       ├── SettingsView.swift
│   │       ├── HotKeyRecorderView.swift
│   │       └── OnboardingWindowController.swift
│   └── DontsToolCore/
│       ├── Core/
│       │   ├── AppInfo.swift
│       │   ├── Models.swift
│       │   ├── Protocols.swift
│       │   ├── Logging.swift
│       │   ├── PathDisplay.swift
│       │   ├── FuzzyMatcher.swift
│       │   ├── QueryParser.swift
│       │   ├── SettingsStore.swift
│       │   ├── HotKeyFormatter.swift
│       │   ├── UsageStore.swift
│       │   ├── ToolRegistry.swift
│       │   └── SearchCoordinator.swift
│       ├── Index/
│       │   ├── AppScanner.swift
│       │   ├── AppIndex.swift
│       │   └── FileSearchService.swift
│       ├── Providers/
│       │   ├── AppProvider.swift
│       │   ├── TextTransformers.swift
│       │   ├── TextToolsProvider.swift
│       │   ├── WebSearchProvider.swift
│       │   ├── FileProvider.swift
│       │   └── TranslationProvider.swift
│       └── Services/
│           ├── SystemServices.swift
│           └── TranslationService.swift
├── Tests/
│   └── DontsToolCoreTests/
│       ├── TestSupport.swift
│       ├── Mocks.swift
│       ├── SmokeTests.swift
│       ├── QueryParserTests.swift
│       ├── FuzzyMatcherTests.swift
│       ├── SettingsStoreTests.swift
│       ├── UsageStoreTests.swift
│       ├── AppScannerTests.swift
│       ├── SearchCoordinatorTests.swift
│       ├── AppProviderTests.swift
│       ├── TextTransformersTests.swift
│       ├── TextToolsProviderTests.swift
│       ├── WebSearchProviderTests.swift
│       ├── FileSearchServiceTests.swift
│       └── TranslationProviderTests.swift
└── docs/
```

`DontsTool.xcodeproj` 与 `build/` 都是生成物，不手改、不提交。

---

## M1：基础壳与原生手感

### Task 1: XcodeGen 工程与最小菜单栏 App

**Files:**
- Create: `project.yml`
- Create: `Makefile`
- Create: `.gitignore`
- Create: `Resources/Info.plist`
- Create: `Sources/DontsTool/DontsToolMain.swift`
- Create: `Sources/DontsTool/App/AppDelegate.swift`
- Create: `Sources/DontsTool/App/AppController.swift`
- Create: `Sources/DontsTool/App/MenuBarController.swift`
- Create: `Sources/DontsToolCore/Core/AppInfo.swift`
- Test: `Tests/DontsToolCoreTests/SmokeTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: `AppInfo.version`；可构建、可测试、可启动的 `.app`。

- [ ] **Step 1: 写工程定义**

`project.yml`：

```yaml
name: DontsTool
options:
  bundleIdPrefix: com.donts
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true
  xcodeVersion: "27.0"

settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "26.0"
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"
    DEVELOPMENT_TEAM: ""
    ENABLE_HARDENED_RUNTIME: NO
    ENABLE_APP_SANDBOX: NO
    CLANG_ENABLE_MODULES: YES

targets:
  DontsToolCore:
    type: library.static
    platform: macOS
    sources:
      - path: Sources/DontsToolCore
    settings:
      base:
        PRODUCT_MODULE_NAME: DontsToolCore
        DEFINES_MODULE: YES
        SKIP_INSTALL: YES

  DontsTool:
    type: application
    platform: macOS
    sources:
      - path: Sources/DontsTool
    dependencies:
      - target: DontsToolCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.donts.DontsTool
        INFOPLIST_FILE: Resources/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"

  DontsToolCoreTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests/DontsToolCoreTests
    dependencies:
      - target: DontsToolCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.donts.DontsToolCoreTests
        GENERATE_INFOPLIST_FILE: YES

schemes:
  DontsTool:
    build:
      targets:
        DontsTool: all
        DontsToolCoreTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - DontsToolCoreTests
    archive:
      config: Release
```

`Resources/Info.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>com.donts.DontsTool</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DontsTool</string>
    <key>CFBundleDisplayName</key>
    <string>DontsTool</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 donts</string>
</dict>
</plist>
```

`Makefile`：

```make
APP_NAME := DontsTool
PROJECT := DontsTool.xcodeproj
SCHEME := DontsTool
CONFIG ?= Debug
DERIVED := build
APP := $(DERIVED)/Build/Products/$(CONFIG)/$(APP_NAME).app

.PHONY: project build app run test release clean distclean

project:
	xcodegen generate --spec project.yml

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) build

app: build
	@test -d "$(APP)" || (echo "未找到 $(APP)"; exit 1)
	@echo "构建完成: $(APP)"

run: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open "$(APP)" --args $(ARGS)

test: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) test

release: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(DERIVED) build
	ditto -c -k --keepParent "$(DERIVED)/Build/Products/Release/$(APP_NAME).app" \
		"$(DERIVED)/$(APP_NAME)-0.1.0.zip"

clean:
	rm -rf $(DERIVED)

distclean: clean
	rm -rf $(PROJECT)
```

`.gitignore`：

```gitignore
.DS_Store
build/
DontsTool.xcodeproj/
*.xcuserstate
DerivedData/
```

- [ ] **Step 2: 写最小 App 骨架**

`Sources/DontsToolCore/Core/AppInfo.swift`：

```swift
import Foundation

public enum AppInfo {
    public static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    public static let bundleIdentifier = "com.donts.DontsTool"
    public static let displayName = "DontsTool"
}
```

`Tests/DontsToolCoreTests/SmokeTests.swift`：

```swift
import Testing
@testable import DontsToolCore

@Suite("Core 模块")
struct SmokeTests {
    @Test func appInfoIsAvailable() {
        #expect(AppInfo.displayName == "DontsTool")
        #expect(!AppInfo.version.isEmpty)
    }
}
```

`Sources/DontsTool/DontsToolMain.swift`：

```swift
import AppKit

@main
enum DontsToolMain {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
```

`Sources/DontsTool/App/AppDelegate.swift`：

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
```

`Sources/DontsTool/App/AppController.swift`（本任务只放菜单栏与退出，后续任务扩展）：

```swift
import AppKit
import DontsToolCore

@MainActor
final class AppController {
    private var menuBar: MenuBarController?

    func start() {
        let menuBar = MenuBarController()
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.install()
        self.menuBar = menuBar
    }

    func shutdown() {}
}
```

`Sources/DontsTool/App/MenuBarController.swift`：

```swift
import AppKit

@MainActor
final class MenuBarController: NSObject {
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "DontsTool")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "DontsTool"

        let menu = NSMenu()
        let quit = NSMenuItem(title: "退出 DontsTool", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func quit() {
        onQuit?()
    }
}
```

- [ ] **Step 3: 生成工程并跑测试**

Run:

```bash
make project
make test
```

Expected: `xcodegen` 生成 `DontsTool.xcodeproj`；`xcodebuild test` 成功，1 个测试通过。若 `library.static` 或签名设置导致 XcodeGen / xcodebuild 报错，先修正 `project.yml`（优先保持静态库 + ad-hoc 签名），再继续。

- [ ] **Step 4: 构建并启动**

Run:

```bash
make app
open build/Build/Products/Debug/DontsTool.app
```

Expected: 菜单栏出现放大镜图标，菜单可退出；Dock 无图标。

---

### Task 2: 核心模型、协议、查询解析与模糊匹配

**Files:**
- Create: `Sources/DontsToolCore/Core/Models.swift`
- Create: `Sources/DontsToolCore/Core/Protocols.swift`
- Create: `Sources/DontsToolCore/Core/Logging.swift`
- Create: `Sources/DontsToolCore/Core/PathDisplay.swift`
- Create: `Sources/DontsToolCore/Core/FuzzyMatcher.swift`
- Create: `Sources/DontsToolCore/Core/QueryParser.swift`
- Test: `Tests/DontsToolCoreTests/QueryParserTests.swift`
- Test: `Tests/DontsToolCoreTests/FuzzyMatcherTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: `SearchContext`、`SearchItem`、`ItemAction`、`ToolProvider`、`ProviderID`、`ActionError`、`QueryParser.parse(_:routes:frontmostBundleID:)`、`FuzzyMatcher.score(query:candidate:)`、`PathDisplay.abbreviated(_:)`。

- [ ] **Step 1: 写失败测试**

`Tests/DontsToolCoreTests/QueryParserTests.swift`：

```swift
import Testing
@testable import DontsToolCore

@Suite("QueryParser")
struct QueryParserTests {
    private let routes: [String: KeywordRoute] = [
        "json": KeywordRoute(providerID: "text", keyword: "json"),
        "tr": KeywordRoute(providerID: "translation", keyword: "tr")
    ]

    @Test func globalModeTrimsWhitespace() {
        let context = QueryParser.parse("  chrome  ", routes: routes)
        #expect(context.mode == .global)
        #expect(context.query == "chrome")
    }

    @Test func keywordModeIsCaseInsensitive() {
        let context = QueryParser.parse("JSON {\"a\":1}", routes: routes)
        #expect(context.mode == .keyword(providerID: "text", keyword: "json", argument: "{\"a\":1}"))
    }

    @Test func keywordWithEmptyArgument() {
        let context = QueryParser.parse("tr", routes: routes)
        #expect(context.mode == .keyword(providerID: "translation", keyword: "tr", argument: ""))
    }

    @Test func keywordArgumentKeepsInternalSpaces() {
        let context = QueryParser.parse("tr   hello world  ", routes: routes)
        #expect(context.mode == .keyword(providerID: "translation", keyword: "tr", argument: "hello world"))
    }

    @Test func chineseQueryStaysGlobal() {
        let context = QueryParser.parse("微信", routes: routes)
        #expect(context.mode == .global)
        #expect(context.query == "微信")
    }
}
```

`Tests/DontsToolCoreTests/FuzzyMatcherTests.swift`：

```swift
import Testing
@testable import DontsToolCore

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test func exactMatchWins() {
        #expect(FuzzyMatcher.score(query: "Chrome", candidate: "Chrome") == 1000)
    }

    @Test func prefixBeatsWordPrefix() {
        let prefix = FuzzyMatcher.score(query: "chr", candidate: "Chrome")!
        let wordPrefix = FuzzyMatcher.score(query: "chr", candidate: "Google Chrome")!
        #expect(prefix == 900)
        #expect(wordPrefix == 800)
        #expect(prefix > wordPrefix)
    }

    @Test func substringScoresAboveSubsequence() {
        let substring = FuzzyMatcher.score(query: "rome", candidate: "Chrome")!
        let subsequence = FuzzyMatcher.score(query: "gcm", candidate: "Google Chrome")!
        #expect(substring >= 650)
        #expect(subsequence >= 300 && subsequence <= 600)
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(FuzzyMatcher.score(query: "cafe", candidate: "Café") == 1000)
    }

    @Test func unmatchedReturnsNil() {
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "Chrome") == nil)
    }

    @Test func emptyQueryReturnsNil() {
        #expect(FuzzyMatcher.score(query: "  ", candidate: "Chrome") == nil)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make test`
Expected: 编译失败，`SearchContext` / `FuzzyMatcher` 等类型不存在。

- [ ] **Step 3: 实现模型与协议**

`Sources/DontsToolCore/Core/Models.swift`：

```swift
import Foundation

public enum ProviderID: String, CaseIterable, Identifiable, Sendable {
    case app
    case file
    case text
    case web
    case translation

    public var id: String { rawValue }
}

public enum SearchMode: Equatable, Sendable {
    case global
    case keyword(providerID: String, keyword: String, argument: String)
}

public struct SearchContext: Equatable, Sendable {
    public let rawQuery: String
    public let mode: SearchMode
    public let frontmostBundleID: String?

    public init(rawQuery: String, mode: SearchMode, frontmostBundleID: String? = nil) {
        self.rawQuery = rawQuery
        self.mode = mode
        self.frontmostBundleID = frontmostBundleID
    }

    public var query: String {
        switch mode {
        case .global:
            rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        case .keyword(_, _, let argument):
            argument
        }
    }
}

public struct KeywordRoute: Equatable, Sendable {
    public let providerID: String
    public let keyword: String

    public init(providerID: String, keyword: String) {
        self.providerID = providerID
        self.keyword = keyword
    }
}

public enum ResultGroup: Int, CaseIterable, Comparable, Sendable {
    case app = 0
    case tool = 1
    case file = 2
    case web = 3

    public static func < (lhs: ResultGroup, rhs: ResultGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ItemIcon: Equatable, Sendable {
    case application(path: String)
    case file(path: String)
    case symbol(name: String)
}

public enum ActionPresentation: Sendable {
    case dismissThenRun
    case keepPanelUntilComplete
    case keepPanelOpen
}

public struct ItemAction {
    public let id: String
    public let title: String
    public let presentation: ActionPresentation
    public let run: @MainActor () async throws -> Void

    public init(
        id: String,
        title: String,
        presentation: ActionPresentation = .dismissThenRun,
        run: @escaping @MainActor () async throws -> Void
    ) {
        self.id = id
        self.title = title
        self.presentation = presentation
        self.run = run
    }
}

public struct SearchItem: Identifiable {
    public let id: String
    public let providerID: String
    public let group: ResultGroup
    public let title: String
    public let subtitle: String?
    public let icon: ItemIcon
    public let score: Double
    public let canonicalKey: String
    public let actions: [ItemAction]

    public init(
        id: String? = nil,
        providerID: String,
        group: ResultGroup,
        title: String,
        subtitle: String? = nil,
        icon: ItemIcon,
        score: Double,
        canonicalKey: String,
        actions: [ItemAction]
    ) {
        self.id = id ?? "\(providerID):\(canonicalKey)"
        self.providerID = providerID
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.score = score
        self.canonicalKey = canonicalKey
        self.actions = actions
    }

    public var primaryAction: ItemAction? { actions.first }
    public var secondaryAction: ItemAction? { actions.dropFirst().first }
}
```

`Sources/DontsToolCore/Core/Protocols.swift`：

```swift
import Foundation

@MainActor
public protocol ClipboardProviding: AnyObject {
    func readString() -> String?
    func writeString(_ string: String)
}

@MainActor
public protocol FeedbackProviding: AnyObject {
    func show(_ message: String)
}

@MainActor
public protocol ProgressReporting: AnyObject {
    func begin(_ message: String)
    func end()
}

@MainActor
public protocol AppLaunching: AnyObject {
    func openApplication(at url: URL) async throws
    func openFile(at url: URL) throws
    func revealInFinder(_ url: URL)
}

@MainActor
public protocol URLOpening: AnyObject {
    func open(_ url: URL) throws
}

@MainActor
public protocol QueryPrefilling: AnyObject {
    func prefill(_ query: String)
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult
}

public struct CommandResult: Sendable {
    public let output: String
    public let terminationStatus: Int32
    public let timedOut: Bool

    public init(output: String, terminationStatus: Int32, timedOut: Bool) {
        self.output = output
        self.terminationStatus = terminationStatus
        self.timedOut = timedOut
    }
}

public enum ActionError: LocalizedError, Equatable {
    case clipboardEmpty
    case invalidInput(String)
    case openFailed(String)
    case commandFailed(String)
    case translationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .clipboardEmpty: "剪贴板为空"
        case .invalidInput(let message): message
        case .openFailed(let target): "无法打开\(target)"
        case .commandFailed(let message): message
        case .translationFailed(let message): message
        }
    }
}
```

`Sources/DontsToolCore/Core/Logging.swift`：

```swift
import os

public enum Log {
    private static let subsystem = "com.donts.DontsTool"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let search = Logger(subsystem: subsystem, category: "search")
    public static let provider = Logger(subsystem: subsystem, category: "provider")
    public static let translation = Logger(subsystem: subsystem, category: "translation")
    public static let index = Logger(subsystem: subsystem, category: "index")
}
```

`Sources/DontsToolCore/Core/PathDisplay.swift`：

```swift
import Foundation

public enum PathDisplay {
    public static func abbreviated(_ path: String) -> String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    public static func parentDirectory(of url: URL) -> String {
        abbreviated(url.deletingLastPathComponent().path)
    }
}
```

`Sources/DontsToolCore/Core/FuzzyMatcher.swift`：

```swift
import Foundation

public enum FuzzyMatcher {
    public static func score(query: String, candidate: String) -> Double? {
        let q = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let c = normalize(candidate)
        guard !q.isEmpty, !c.isEmpty else { return nil }

        if q == c { return 1000 }
        if c.hasPrefix(q) { return 900 }
        if hasWordPrefix(q, in: c) { return 800 }
        if let range = c.range(of: q) {
            let position = c.distance(from: c.startIndex, to: range.lowerBound)
            return max(700 - Double(position), 650)
        }
        if let density = subsequenceDensity(q, in: c) {
            return 300 + 300 * density
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    private static func hasWordPrefix(_ query: String, in candidate: String) -> Bool {
        let separators = CharacterSet.alphanumerics.inverted
        return candidate
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .contains { $0.hasPrefix(query) }
    }

    private static func subsequenceDensity(_ query: String, in candidate: String) -> Double? {
        var queryIndex = query.startIndex
        var firstMatch: Int?
        var lastMatch = 0
        var candidateIndex = 0

        for character in candidate {
            if queryIndex < query.endIndex, character == query[queryIndex] {
                if firstMatch == nil { firstMatch = candidateIndex }
                lastMatch = candidateIndex
                queryIndex = query.index(after: queryIndex)
            }
            candidateIndex += 1
        }

        guard queryIndex == query.endIndex, let firstMatch else { return nil }
        let span = max(1, lastMatch - firstMatch + 1)
        return Double(query.count) / Double(span)
    }
}
```

`Sources/DontsToolCore/Core/QueryParser.swift`：

```swift
import Foundation

public enum QueryParser {
    public static func parse(
        _ raw: String,
        routes: [String: KeywordRoute],
        frontmostBundleID: String? = nil
    ) -> SearchContext {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchContext(rawQuery: raw, mode: .global, frontmostBundleID: frontmostBundleID)
        }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let head = String(parts[0]).lowercased()
        if let route = routes[head] {
            let argument = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            return SearchContext(
                rawQuery: raw,
                mode: .keyword(providerID: route.providerID, keyword: route.keyword, argument: argument),
                frontmostBundleID: frontmostBundleID
            )
        }

        return SearchContext(rawQuery: raw, mode: .global, frontmostBundleID: frontmostBundleID)
    }
}
```

- [ ] **Step 4: 运行测试**

Run: `make test`
Expected: `QueryParserTests` 与 `FuzzyMatcherTests` 全部通过。

---

### Task 3: 设置、使用统计与热键格式化

**Files:**
- Create: `Sources/DontsToolCore/Core/SettingsStore.swift`
- Create: `Sources/DontsToolCore/Core/HotKeyFormatter.swift`
- Create: `Sources/DontsToolCore/Core/UsageStore.swift`
- Test: `Tests/DontsToolCoreTests/SettingsStoreTests.swift`
- Test: `Tests/DontsToolCoreTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `SettingsStore.HotKeyConfiguration`（`keyCode: UInt32`、`modifiers: UInt32`、`.optionSpace`）
  - `SettingsStore.SearchEngine`（`google` / `bing` / `baidu` / `ddg`，`searchURL(for:)`）
  - `SettingsStore` 公开只读属性与 setter
  - `HotKeyFormatter.displayString(for:)`
  - `UsageStore.recordUse(of:at:)` / `boost(for:now:)` / `topKeys(limit:)` / `flush()`

- [ ] **Step 1: 写失败测试**

`Tests/DontsToolCoreTests/SettingsStoreTests.swift`：

```swift
import Foundation
import Testing
@testable import DontsToolCore

@Suite("SettingsStore")
@MainActor
struct SettingsStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "dontstool.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaultsAreStable() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "zh")

        #expect(store.hotKey == .optionSpace)
        #expect(store.defaultSearchEngine == .google)
        #expect(store.enabledProviderIDs == Set(ProviderID.allCases.map(\.rawValue)))
        #expect(store.fileSearchEnabled)
        #expect(store.translationTarget == "zh-Hans")
        #expect(!store.hasCompletedOnboarding)
    }

    @Test func changesPersist() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "en")

        store.setHotKey(.init(keyCode: 1, modifiers: 2048))
        store.setDefaultSearchEngine(.bing)
        store.setProviderEnabled(ProviderID.web.rawValue, to: false)
        store.setFileSearchEnabled(false)
        store.setTranslationTarget("ja")
        store.completeOnboarding()

        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloaded.hotKey == .init(keyCode: 1, modifiers: 2048))
        #expect(reloaded.defaultSearchEngine == .bing)
        #expect(!reloaded.isProviderEnabled(ProviderID.web.rawValue))
        #expect(!reloaded.fileSearchEnabled)
        #expect(reloaded.translationTarget == "ja")
        #expect(reloaded.hasCompletedOnboarding)
    }

    @Test func disablingAllProvidersPersistsEmptySet() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        for id in ProviderID.allCases {
            store.setProviderEnabled(id.rawValue, to: false)
        }

        let reloaded = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        #expect(reloaded.enabledProviderIDs.isEmpty)
    }

    @Test func searchEngineBuildsEncodedURL() {
        let url = SettingsStore.SearchEngine.google.searchURL(for: "swift concurrency + 中文")
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        #expect(components?.host == "www.google.com")
        #expect(components?.queryItems?.first?.value == "swift concurrency + 中文")
    }
}
```

`Tests/DontsToolCoreTests/UsageStoreTests.swift`：

```swift
import Foundation
import Testing
@testable import DontsToolCore

@Suite("UsageStore")
@MainActor
struct UsageStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "dontstool.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func recordsCountAndBoost() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(defaults: defaults, now: { now })

        store.recordUse(of: "/Applications/Chrome.app", at: now)
        store.recordUse(of: "/Applications/Chrome.app", at: now)

        #expect(store.record(for: "/Applications/Chrome.app")?.count == 2)
        let expected = 15 * log2(1.0 + 2.0) + 50.0
        #expect(abs(store.boost(for: "/Applications/Chrome.app", now: now) - expected) < 0.001)
    }

    @Test func oldUseHasNoRecencyBoost() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-8 * 86_400)
        let store = UsageStore(defaults: defaults, now: { now })
        store.recordUse(of: "x", at: old)
        #expect(abs(store.boost(for: "x", now: now) - 15 * log2(2.0)) < 0.001)
    }

    @Test func flushPersistsRecords() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(defaults: defaults, now: { now })
        store.recordUse(of: "a", at: now)
        store.recordUse(of: "b", at: now.addingTimeInterval(1))
        store.flush()

        let reloaded = UsageStore(defaults: defaults, now: { now })
        #expect(reloaded.record(for: "a")?.count == 1)
        #expect(reloaded.record(for: "b")?.count == 1)
    }

    @Test func topKeysSortsRecentFirst() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(defaults: defaults, now: { now })
        store.recordUse(of: "older", at: now.addingTimeInterval(-100))
        store.recordUse(of: "newer", at: now)
        #expect(store.topKeys(limit: 2) == ["newer", "older"])
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make test`
Expected: `SettingsStore` / `UsageStore` 不存在。

- [ ] **Step 3: 实现设置与热键显示**

`Sources/DontsToolCore/Core/SettingsStore.swift`：

```swift
import Combine
import Foundation

@MainActor
public final class SettingsStore: ObservableObject {
    public struct HotKeyConfiguration: Equatable, Codable, Sendable {
        public var keyCode: UInt32
        public var modifiers: UInt32

        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        public static let optionSpace = HotKeyConfiguration(keyCode: 49, modifiers: 2048)
    }

    public enum SearchEngine: String, CaseIterable, Identifiable, Codable, Sendable {
        case google
        case bing
        case baidu
        case ddg

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .google: "Google"
            case .bing: "必应"
            case .baidu: "百度"
            case .ddg: "DuckDuckGo"
            }
        }

        public func searchURL(for query: String) -> URL? {
            var components = URLComponents()
            components.scheme = "https"
            switch self {
            case .google:
                components.host = "www.google.com"
                components.path = "/search"
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            case .bing:
                components.host = "www.bing.com"
                components.path = "/search"
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            case .baidu:
                components.host = "www.baidu.com"
                components.path = "/s"
                components.queryItems = [URLQueryItem(name: "wd", value: query)]
            case .ddg:
                components.host = "duckduckgo.com"
                components.path = "/"
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            }
            return components.url
        }
    }

    private enum Key {
        static let hotKeyCode = "dontstool.hotkey.keyCode"
        static let hotKeyModifiers = "dontstool.hotkey.modifiers"
        static let defaultSearchEngine = "dontstool.defaultSearchEngine"
        static let enabledProviders = "dontstool.enabledProviders"
        static let fileSearchEnabled = "dontstool.fileSearchEnabled"
        static let translationTarget = "dontstool.translationTarget"
        static let hasCompletedOnboarding = "dontstool.hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    @Published public private(set) var hotKey: HotKeyConfiguration
    @Published public private(set) var defaultSearchEngine: SearchEngine
    @Published public private(set) var enabledProviderIDs: Set<String>
    @Published public private(set) var fileSearchEnabled: Bool
    @Published public private(set) var translationTarget: String
    @Published public private(set) var hasCompletedOnboarding: Bool

    public var hotKeyChanges: AnyPublisher<HotKeyConfiguration, Never> {
        $hotKey.eraseToAnyPublisher()
    }

    public init(defaults: UserDefaults = .standard, systemLanguageCode: String? = nil) {
        self.defaults = defaults

        if defaults.object(forKey: Key.hotKeyCode) != nil {
            hotKey = HotKeyConfiguration(
                keyCode: UInt32(defaults.integer(forKey: Key.hotKeyCode)),
                modifiers: UInt32(defaults.integer(forKey: Key.hotKeyModifiers))
            )
        } else {
            hotKey = .optionSpace
        }

        defaultSearchEngine = SearchEngine(
            rawValue: defaults.string(forKey: Key.defaultSearchEngine) ?? ""
        ) ?? .google

        if let stored = defaults.array(forKey: Key.enabledProviders) as? [String] {
            enabledProviderIDs = Set(stored)
        } else {
            enabledProviderIDs = Set(ProviderID.allCases.map(\.rawValue))
        }

        if defaults.object(forKey: Key.fileSearchEnabled) != nil {
            fileSearchEnabled = defaults.bool(forKey: Key.fileSearchEnabled)
        } else {
            fileSearchEnabled = true
        }

        let languageCode = systemLanguageCode ?? Locale.current.language.languageCode?.identifier
        let fallbackTarget = languageCode == "zh" ? "zh-Hans" : "en"
        translationTarget = defaults.string(forKey: Key.translationTarget) ?? fallbackTarget
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    public func setHotKey(_ configuration: HotKeyConfiguration) {
        hotKey = configuration
        defaults.set(Int(configuration.keyCode), forKey: Key.hotKeyCode)
        defaults.set(Int(configuration.modifiers), forKey: Key.hotKeyModifiers)
    }

    public func setDefaultSearchEngine(_ engine: SearchEngine) {
        defaultSearchEngine = engine
        defaults.set(engine.rawValue, forKey: Key.defaultSearchEngine)
    }

    public func isProviderEnabled(_ id: String) -> Bool {
        enabledProviderIDs.contains(id)
    }

    public func setProviderEnabled(_ id: String, to isEnabled: Bool) {
        if isEnabled {
            enabledProviderIDs.insert(id)
        } else {
            enabledProviderIDs.remove(id)
        }
        defaults.set(Array(enabledProviderIDs).sorted(), forKey: Key.enabledProviders)
    }

    public func setFileSearchEnabled(_ isEnabled: Bool) {
        fileSearchEnabled = isEnabled
        defaults.set(isEnabled, forKey: Key.fileSearchEnabled)
    }

    public func setTranslationTarget(_ identifier: String) {
        translationTarget = identifier
        defaults.set(identifier, forKey: Key.translationTarget)
    }

    public func completeOnboarding() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Key.hasCompletedOnboarding)
    }

    public func resetOnboarding() {
        hasCompletedOnboarding = false
        defaults.set(false, forKey: Key.hasCompletedOnboarding)
    }
}
```

`Sources/DontsToolCore/Core/HotKeyFormatter.swift`：

```swift
import Foundation

public enum HotKeyFormatter {
    private static let modifierSymbols: [(UInt32, String)] = [
        (4096, "⌃"),
        (2048, "⌥"),
        (512, "⇧"),
        (256, "⌘")
    ]

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 115: "Home", 116: "PageUp",
        117: "ForwardDelete", 118: "F4", 119: "End", 120: "F2", 121: "PageDown", 122: "F1"
    ]

    public static func displayString(for configuration: SettingsStore.HotKeyConfiguration) -> String {
        let modifiers = modifierSymbols
            .filter { configuration.modifiers & $0.0 != 0 }
            .map(\.1)
            .joined()
        let key = keyNames[configuration.keyCode] ?? "Key\(configuration.keyCode)"
        return modifiers + key
    }
}
```

- [ ] **Step 4: 实现使用统计**

`Sources/DontsToolCore/Core/UsageStore.swift`：

```swift
import Foundation

@MainActor
public final class UsageStore {
    public struct Record: Codable, Equatable, Sendable {
        public var count: Int
        public var lastUsed: Date

        public init(count: Int, lastUsed: Date) {
            self.count = count
            self.lastUsed = lastUsed
        }
    }

    private enum Key {
        static let records = "dontstool.usage.records"
    }

    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private var records: [String: Record]
    private var flushTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Key.records),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    public func recordUse(of key: String, at date: Date? = nil) {
        let timestamp = date ?? now()
        var record = records[key] ?? Record(count: 0, lastUsed: timestamp)
        record.count += 1
        record.lastUsed = timestamp
        records[key] = record
        scheduleFlush()
    }

    public func record(for key: String) -> Record? {
        records[key]
    }

    public func boost(for key: String, now date: Date? = nil) -> Double {
        guard let record = records[key] else { return 0 }
        let current = date ?? now()
        let usageBoost = min(100, 15 * log2(1 + Double(record.count)))
        let age = current.timeIntervalSince(record.lastUsed)
        let recencyBoost: Double
        if age <= 86_400 {
            recencyBoost = 50
        } else if age <= 7 * 86_400 {
            recencyBoost = 20
        } else {
            recencyBoost = 0
        }
        return usageBoost + recencyBoost
    }

    public func topKeys(limit: Int) -> [String] {
        records
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                if $0.value.lastUsed != $1.value.lastUsed { return $0.value.lastUsed > $1.value.lastUsed }
                return $0.key < $1.key
            }
            .prefix(limit)
            .map(\.key)
    }

    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Key.records)
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
```

- [ ] **Step 5: 运行测试**

Run: `make test`
Expected: 设置与使用统计测试全部通过。

---

### Task 4: 应用索引

**Files:**
- Create: `Sources/DontsToolCore/Index/AppScanner.swift`
- Create: `Sources/DontsToolCore/Index/AppIndex.swift`
- Test: `Tests/DontsToolCoreTests/AppScannerTests.swift`

**Interfaces:**
- Consumes: `Log.index`
- Produces:
  - `AppEntry`（`id` = 标准化路径）
  - `AppScanResult`（`entries`、`failedRoots`）
  - `AppScanner(roots:)`、`AppScanner.defaultRoots`、`scan()`
  - `AppIndex.apps` / `isScanning` / `scan() async`

- [ ] **Step 1: 写失败测试**

`Tests/DontsToolCoreTests/AppScannerTests.swift`：

```swift
import Foundation
import Testing
@testable import DontsToolCore

@Suite("AppScanner")
struct AppScannerTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DontsToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(at root: URL, name: String, plist: [String: Any]) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    @Test func readsDisplayNameThenBundleNameThenFileName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApp(at: root, name: "A.app", plist: ["CFBundleDisplayName": "Alpha", "CFBundleName": "AlphaBundle"])
        _ = try makeApp(at: root, name: "B.app", plist: ["CFBundleName": "Beta"])
        _ = try makeApp(at: root, name: "Gamma.app", plist: [:])

        let result = AppScanner(roots: [root]).scan()
        let names = Set(result.entries.map(\.displayName))
        #expect(names.contains("Alpha"))
        #expect(names.contains("Beta"))
        #expect(names.contains("Gamma"))
    }

    @Test func scansOneLevelOfSubdirectories() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        _ = try makeApp(at: group, name: "Terminal.app", plist: ["CFBundleName": "Terminal"])

        let result = AppScanner(roots: [root]).scan()
        #expect(result.entries.map(\.displayName).contains("Terminal"))
    }

    @Test func skipsNestedAppsInsidePackages() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = try makeApp(at: root, name: "Outer.app", plist: ["CFBundleName": "Outer"])
        let helpers = outer.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        _ = try makeApp(at: helpers, name: "Helper.app", plist: ["CFBundleName": "Helper"])

        let result = AppScanner(roots: [root]).scan()
        #expect(result.entries.map(\.displayName) == ["Outer"])
    }

    @Test func skipsBackgroundOnlyApps() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeApp(at: root, name: "Visible.app", plist: ["CFBundleName": "Visible"])
        _ = try makeApp(at: root, name: "Hidden.app", plist: ["CFBundleName": "Hidden", "LSBackgroundOnly": true])

        let result = AppScanner(roots: [root]).scan()
        #expect(result.entries.map(\.displayName) == ["Visible"])
    }

    @Test func skipsHiddenDirectories() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".HiddenGroup", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        _ = try makeApp(at: hidden, name: "Secret.app", plist: ["CFBundleName": "Secret"])

        let result = AppScanner(roots: [root]).scan()
        #expect(result.entries.isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make test`
Expected: `AppScanner` 不存在。

- [ ] **Step 3: 实现扫描与索引**

`Sources/DontsToolCore/Index/AppScanner.swift`：

```swift
import Foundation

public struct AppEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let bundleID: String?
    public let url: URL
    public let modifiedAt: Date?

    public init(id: String, displayName: String, bundleID: String?, url: URL, modifiedAt: Date?) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.url = url
        self.modifiedAt = modifiedAt
    }
}

public struct AppScanResult: Sendable {
    public let entries: [AppEntry]
    public let failedRoots: [URL]

    public init(entries: [AppEntry], failedRoots: [URL]) {
        self.entries = entries
        self.failedRoots = failedRoots
    }
}

public struct AppScanner: Sendable {
    public let roots: [URL]

    public init(roots: [URL] = AppScanner.defaultRoots) {
        self.roots = roots
    }

    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ]
    }

    public func scan() -> AppScanResult {
        var entriesByPath: [String: AppEntry] = [:]
        var failedRoots: [URL] = []

        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                for child in children {
                    if child.pathExtension.lowercased() == "app" {
                        if let entry = makeEntry(at: child) {
                            entriesByPath[entry.id] = entry
                        }
                    } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        let grandchildren = try FileManager.default.contentsOfDirectory(
                            at: child,
                            includingPropertiesForKeys: [.contentModificationDateKey],
                            options: [.skipsHiddenFiles]
                        )
                        for grandchild in grandchildren where grandchild.pathExtension.lowercased() == "app" {
                            if let entry = makeEntry(at: grandchild) {
                                entriesByPath[entry.id] = entry
                            }
                        }
                    }
                }
            } catch {
                Log.index.error("扫描应用目录失败: \(root.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
                failedRoots.append(root)
            }
        }

        let entries = entriesByPath.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return AppScanResult(entries: entries, failedRoots: failedRoots)
    }

    private func makeEntry(at url: URL) -> AppEntry? {
        guard let bundle = Bundle(url: url),
              let info = bundle.infoDictionary else {
            return nil
        }

        if isTrue(info["LSBackgroundOnly"]) {
            return nil
        }

        let name = (info["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (info["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let displayName = name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
        let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let standardized = url.standardizedFileURL

        return AppEntry(
            id: standardized.path,
            displayName: displayName,
            bundleID: info["CFBundleIdentifier"] as? String,
            url: standardized,
            modifiedAt: modifiedAt
        )
    }

    private func isTrue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            return string == "1" || string.lowercased() == "true"
        }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
```

`Sources/DontsToolCore/Index/AppIndex.swift`：

```swift
import Foundation

@MainActor
public final class AppIndex: ObservableObject {
    @Published public private(set) var apps: [AppEntry] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var lastError: String?

    private let scanner: AppScanner
    private var scanTask: Task<Void, Never>?

    public init(scanner: AppScanner = AppScanner()) {
        self.scanner = scanner
    }

    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        let scanner = self.scanner
        let result = await Task.detached(priority: .utility) {
            scanner.scan()
        }.value

        if !result.entries.isEmpty || result.failedRoots.isEmpty {
            apps = result.entries
        } else {
            lastError = "应用索引扫描失败"
            Log.index.error("所有应用目录均扫描失败，保留旧快照")
        }
        isScanning = false
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
}
```

注：`cancelScan` 目前不会被调用；如果实现时发现无效代码，直接删除，不要保留占位。

- [ ] **Step 4: 运行测试**

Run: `make test`
Expected: `AppScannerTests` 全部通过。

---

### Task 5: Provider 注册与两阶段搜索聚合

**Files:**
- Create: `Sources/DontsToolCore/Core/ToolRegistry.swift`
- Create: `Sources/DontsToolCore/Core/SearchCoordinator.swift`
- Test: `Tests/DontsToolCoreTests/Mocks.swift`
- Test: `Tests/DontsToolCoreTests/SearchCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ToolProvider`、`QueryParser`、`SearchItem`
- Produces:
  - `ToolProvider` 协议（含 `phase`、`statusNotice`）
  - `ToolRegistry(providers:)`、`enabledProviders`、`enabledKeywordRoutes()`
  - `SearchCoordinator(registry:slowDelay:)`、`submit(_:frontmostBundleID:)`、`onUpdate`、`Status`
  - 测试辅助 `MockProvider`、`makeItem(...)`

- [ ] **Step 1: 增加 ToolProvider 协议与 Mock**

在 `Models.swift` 末尾追加：

```swift
public enum SearchPhase: Sendable {
    case fast
    case slow
}

@MainActor
public protocol ToolProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var keywords: [String] { get }
    var priority: Int { get }
    var isEnabled: Bool { get set }
    var phase: SearchPhase { get }
    var statusNotice: String? { get }

    func search(_ context: SearchContext) async -> [SearchItem]
}

extension ToolProvider {
    public var phase: SearchPhase { .fast }
    public var statusNotice: String? { nil }
}
```

`Tests/DontsToolCoreTests/Mocks.swift`：

```swift
import Foundation
@testable import DontsToolCore

@MainActor
final class MockProvider: ToolProvider {
    let id: String
    let displayName: String
    var keywords: [String]
    var priority: Int
    var isEnabled: Bool
    var phase: SearchPhase
    var statusNotice: String?
    var searchHandler: (SearchContext) async -> [SearchItem]
    private(set) var receivedQueries: [String] = []

    init(
        id: String,
        displayName: String = "Mock",
        keywords: [String] = [],
        priority: Int = 0,
        isEnabled: Bool = true,
        phase: SearchPhase = .fast,
        statusNotice: String? = nil,
        searchHandler: @escaping (SearchContext) async -> [SearchItem] = { _ in [] }
    ) {
        self.id = id
        self.displayName = displayName
        self.keywords = keywords
        self.priority = priority
        self.isEnabled = isEnabled
        self.phase = phase
        self.statusNotice = statusNotice
        self.searchHandler = searchHandler
    }

    func search(_ context: SearchContext) async -> [SearchItem] {
        receivedQueries.append(context.query)
        return await searchHandler(context)
    }
}

func makeItem(
    providerID: String = "mock",
    group: ResultGroup = .tool,
    title: String = "Item",
    score: Double = 0,
    canonicalKey: String = UUID().uuidString
) -> SearchItem {
    SearchItem(
        providerID: providerID,
        group: group,
        title: title,
        icon: .symbol(name: "circle"),
        score: score,
        canonicalKey: canonicalKey,
        actions: []
    )
}
```

- [ ] **Step 2: 写失败的聚合测试**

`Tests/DontsToolCoreTests/SearchCoordinatorTests.swift`：

```swift
import Testing
@testable import DontsToolCore

@Suite("SearchCoordinator")
@MainActor
struct SearchCoordinatorTests {
    private func makeCoordinator(_ providers: [ToolProvider]) -> SearchCoordinator {
        SearchCoordinator(registry: ToolRegistry(providers: providers), slowDelay: .zero)
    }

    private func collect(_ coordinator: SearchCoordinator) -> () -> [SearchCoordinator.Update] {
        var updates: [SearchCoordinator.Update] = []
        coordinator.onUpdate = { updates.append($0) }
        return { updates }
    }

    @Test func keywordModeQueriesOnlyTargetProvider() async {
        let app = MockProvider(id: "app")
        let text = MockProvider(
            id: "text",
            keywords: ["json"],
            searchHandler: { _ in [makeItem(providerID: "text", canonicalKey: "json")] }
        )
        let coordinator = makeCoordinator([app, text])
        let updates = collect(coordinator)

        coordinator.submit("JSON {}")
        await coordinator.waitForPendingSearch()

        #expect(app.receivedQueries.isEmpty)
        #expect(text.receivedQueries == ["{}"])
        #expect(updates().last?.items.count == 1)
    }

    @Test func disabledProviderIsExcluded() async {
        let enabled = MockProvider(id: "enabled", searchHandler: { _ in [makeItem(canonicalKey: "a")] })
        let disabled = MockProvider(
            id: "disabled",
            isEnabled: false,
            searchHandler: { _ in [makeItem(canonicalKey: "b")] }
        )
        let coordinator = makeCoordinator([enabled, disabled])
        let updates = collect(coordinator)

        coordinator.submit("query")
        await coordinator.waitForPendingSearch()

        #expect(disabled.receivedQueries.isEmpty)
        #expect(updates().last?.items.map(\.canonicalKey) == ["a"])
    }

    @Test func fastAndSlowResultsMerge() async {
        let fast = MockProvider(id: "fast", searchHandler: { _ in [makeItem(group: .app, title: "App", canonicalKey: "app")] })
        let slow = MockProvider(
            id: "slow",
            phase: .slow,
            searchHandler: { _ in [makeItem(group: .file, title: "File", canonicalKey: "file")] }
        )
        let coordinator = makeCoordinator([fast, slow])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().count == 2)
        #expect(updates().first?.status == .searchingFiles)
        #expect(updates().last?.items.map(\.group) == [.app, .file])
        #expect(updates().last?.status == .idle)
    }

    @Test func duplicateCanonicalKeyKeepsHigherScore() async {
        let first = MockProvider(id: "first", searchHandler: { _ in [makeItem(title: "Low", score: 10, canonicalKey: "same")] })
        let second = MockProvider(id: "second", searchHandler: { _ in [makeItem(title: "High", score: 20, canonicalKey: "same")] })
        let coordinator = makeCoordinator([first, second])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.items.count == 1)
        #expect(updates().last?.items.first?.title == "High")
    }

    @Test func groupsAndCapsAreApplied() async {
        let apps = (0..<10).map { makeItem(group: .app, title: "App\($0)", score: Double(10 - $0), canonicalKey: "app\($0)") }
        let tools = (0..<10).map { makeItem(group: .tool, title: "Tool\($0)", score: Double(10 - $0), canonicalKey: "tool\($0)") }
        let provider = MockProvider(id: "p", searchHandler: { _ in apps + tools })
        let coordinator = makeCoordinator([provider])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        let items = updates().last!.items
        #expect(items.filter { $0.group == .app }.count == 8)
        #expect(items.filter { $0.group == .tool }.count == 8)
        #expect(items.first?.group == .app)
        #expect(items.last?.group == .tool)
    }

    @Test func webFallbackIsRemovedWhenLocalResultsExist() async {
        let local = MockProvider(id: "local", searchHandler: { _ in [makeItem(group: .app, canonicalKey: "app")] })
        let web = MockProvider(id: "web", searchHandler: { _ in [makeItem(group: .web, canonicalKey: "web")] })
        let coordinator = makeCoordinator([local, web])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.items.map(\.group) == [.app])
    }

    @Test func webFallbackSurvivesWithoutLocalResults() async {
        let web = MockProvider(id: "web", searchHandler: { _ in [makeItem(group: .web, canonicalKey: "web")] })
        let coordinator = makeCoordinator([web])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.items.map(\.group) == [.web])
    }

    @Test func statusNoticeIsPublished() async {
        let slow = MockProvider(
            id: "file",
            phase: .slow,
            statusNotice: "文件搜索不可用",
            searchHandler: { _ in [] }
        )
        let coordinator = makeCoordinator([slow])
        let updates = collect(coordinator)

        coordinator.submit("q")
        await coordinator.waitForPendingSearch()

        #expect(updates().last?.status == .message("文件搜索不可用"))
    }

    @Test func emptyQuerySkipsSlowProviders() async {
        let fast = MockProvider(id: "fast", searchHandler: { _ in [makeItem(group: .app, canonicalKey: "app")] })
        let slow = MockProvider(id: "slow", phase: .slow, searchHandler: { _ in [makeItem(canonicalKey: "slow")] })
        let coordinator = makeCoordinator([fast, slow])
        let updates = collect(coordinator)

        coordinator.submit("")
        await coordinator.waitForPendingSearch()

        #expect(slow.receivedQueries.isEmpty)
        #expect(updates().last?.items.count == 1)
    }
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `make test`
Expected: `ToolRegistry` / `SearchCoordinator` 不存在。

- [ ] **Step 4: 实现注册表**

`Sources/DontsToolCore/Core/ToolRegistry.swift`：

```swift
import Foundation

@MainActor
public final class ToolRegistry {
    public let providers: [ToolProvider]

    public init(providers: [ToolProvider]) {
        self.providers = providers
    }

    public var enabledProviders: [ToolProvider] {
        providers.filter(\.isEnabled)
    }

    public func provider(for id: String) -> ToolProvider? {
        providers.first { $0.id == id }
    }

    public func enabledKeywordRoutes() -> [String: KeywordRoute] {
        var routes: [String: KeywordRoute] = [:]
        let ordered = providers
            .filter(\.isEnabled)
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.id < $1.id
            }

        for provider in ordered {
            for keyword in provider.keywords {
                let normalized = keyword.lowercased()
                if let existing = routes[normalized] {
                    Log.provider.warning(
                        "关键词冲突: \(normalized, privacy: .public) 已被 \(existing.providerID, privacy: .public) 占用，忽略 \(provider.id, privacy: .public)"
                    )
                    continue
                }
                routes[normalized] = KeywordRoute(providerID: provider.id, keyword: normalized)
            }
        }
        return routes
    }
}
```

- [ ] **Step 5: 实现聚合器**

`Sources/DontsToolCore/Core/SearchCoordinator.swift`：

```swift
import Foundation

@MainActor
public final class SearchCoordinator {
    public enum Status: Equatable, Sendable {
        case idle
        case searchingFiles
        case message(String)
    }

    public struct Update {
        public let items: [SearchItem]
        public let status: Status
    }

    public var onUpdate: ((Update) -> Void)?

    private let registry: ToolRegistry
    private let slowDelay: Duration
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    public init(registry: ToolRegistry, slowDelay: Duration = .milliseconds(120)) {
        self.registry = registry
        self.slowDelay = slowDelay
    }

    public func submit(_ rawQuery: String, frontmostBundleID: String? = nil) {
        generation += 1
        let currentGeneration = generation
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.run(
                rawQuery: rawQuery,
                generation: currentGeneration,
                frontmostBundleID: frontmostBundleID
            )
        }
    }

    public func cancel() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
    }

    func waitForPendingSearch() async {
        await searchTask?.value
    }

    private func run(rawQuery: String, generation: Int, frontmostBundleID: String?) async {
        let routes = registry.enabledKeywordRoutes()
        let context = QueryParser.parse(
            rawQuery,
            routes: routes,
            frontmostBundleID: frontmostBundleID
        )
        let enabled = registry.enabledProviders

        let selected: [ToolProvider]
        switch context.mode {
        case .keyword(let providerID, _, _):
            selected = enabled.filter { $0.id == providerID }
        case .global:
            selected = enabled
        }

        let fastProviders = selected.filter { $0.phase == .fast }
        let slowProviders = context.query.isEmpty ? [] : selected.filter { $0.phase == .slow }

        var fastItems: [SearchItem] = []
        for provider in fastProviders {
            let items = await provider.search(context)
            guard isCurrent(generation) else { return }
            fastItems.append(contentsOf: items)
        }

        let fastMerged = merge(fastItems, context: context, allowWeb: slowProviders.isEmpty)
        publish(
            fastMerged,
            status: slowProviders.isEmpty ? .idle : .searchingFiles,
            generation: generation
        )

        guard !slowProviders.isEmpty else { return }
        do {
            try await Task.sleep(for: slowDelay)
        } catch {
            return
        }
        guard isCurrent(generation) else { return }

        var slowItems: [SearchItem] = []
        var notice: String?
        for provider in slowProviders {
            let items = await provider.search(context)
            guard isCurrent(generation) else { return }
            slowItems.append(contentsOf: items)
            if let providerNotice = provider.statusNotice {
                notice = providerNotice
            }
        }

        let merged = merge(fastItems + slowItems, context: context, allowWeb: true)
        publish(merged, status: notice.map(Status.message) ?? .idle, generation: generation)
    }

    private func merge(_ items: [SearchItem], context: SearchContext, allowWeb: Bool) -> [SearchItem] {
        var bestByKey: [String: SearchItem] = [:]
        var order: [String] = []

        for item in items {
            if let existing = bestByKey[item.canonicalKey] {
                if item.score > existing.score {
                    bestByKey[item.canonicalKey] = item
                }
            } else {
                bestByKey[item.canonicalKey] = item
                order.append(item.canonicalKey)
            }
        }

        var merged = order.compactMap { bestByKey[$0] }

        if case .global = context.mode {
            if context.query.isEmpty || !allowWeb {
                merged.removeAll { $0.group == .web }
            } else if merged.contains(where: { $0.group != .web }) {
                merged.removeAll { $0.group == .web }
            }
        }

        merged.sort {
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        let caps: [ResultGroup: Int] = [.app: 8, .tool: 8, .file: 12, .web: 1]
        var counts: [ResultGroup: Int] = [:]
        return merged.filter { item in
            let count = counts[item.group, default: 0]
            guard count < caps[item.group, default: 0] else { return false }
            counts[item.group] = count + 1
            return true
        }
    }

    private func isCurrent(_ expected: Int) -> Bool {
        generation == expected && !Task.isCancelled
    }

    private func publish(_ items: [SearchItem], status: Status, generation: Int) {
        guard isCurrent(generation) else { return }
        onUpdate?(Update(items: items, status: status))
    }
}
```

- [ ] **Step 6: 运行测试**

Run: `make test`
Expected: 聚合测试全部通过。若 `keywordModeQueriesOnlyTargetProvider` 中 `text.receivedQueries` 期望为空，是因为关键词模式下 `SearchContext.query` 是参数而非原始查询；测试同时确认只查询了 target provider。

---

### Task 6: AppProvider 与应用启动

**Files:**
- Create: `Sources/DontsToolCore/Services/SystemServices.swift`
- Create: `Sources/DontsToolCore/Providers/AppProvider.swift`
- Test: `Tests/DontsToolCoreTests/AppProviderTests.swift`

**Interfaces:**
- Consumes: `AppIndex`、`SettingsStore`、`UsageStore`、`AppLaunching`、`FeedbackProviding`、`FuzzyMatcher`
- Produces: `AppProvider`（id `app`，priority 100，fast，无关键词）；系统实现 `SystemAppLauncher`、`SystemClipboard`、`SystemURLOpener`。

- [ ] **Step 1: 写失败测试**

`Tests/DontsToolCoreTests/AppProviderTests.swift`：

```swift
import Foundation
import Testing
@testable import DontsToolCore

@MainActor
final class MockAppLauncher: AppLaunching {
    var openedApplications: [URL] = []
    var revealed: [URL] = []
    var error: Error?

    func openApplication(at url: URL) async throws {
        if let error { throw error }
        openedApplications.append(url)
    }

    func openFile(at url: URL) throws {}

    func revealInFinder(_ url: URL) {
        revealed.append(url)
    }
}

@MainActor
final class MockFeedback: FeedbackProviding {
    var messages: [String] = []
    func show(_ message: String) { messages.append(message) }
}

@Suite("AppProvider")
@MainActor
struct AppProviderTests {
    private func makeEntry(_ name: String, path: String) -> AppEntry {
        AppEntry(
            id: path,
            displayName: name,
            bundleID: nil,
            url: URL(fileURLWithPath: path),
            modifiedAt: nil
        )
    }

    @Test func fuzzyMatchesAndUsesRecencyBoost() async throws {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let usage = UsageStore(defaults: defaults, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        usage.recordUse(of: "/Applications/Chrome.app", at: Date(timeIntervalSince1970: 1_700_000_000))
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([
            makeEntry("Chrome", path: "/Applications/Chrome.app"),
            makeEntry("Chromium", path: "/Applications/Chromium.app")
        ])

        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: usage,
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )
        let items = await provider.search(SearchContext(rawQuery: "chr", mode: .global))
        #expect(items.first?.title == "Chrome")
    }

    @Test func primaryActionLaunchesAndRecordsUse() async throws {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let usage = UsageStore(defaults: defaults, now: { Date() })
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: "/Applications/Safari.app")])
        let launcher = MockAppLauncher()
        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: usage,
            launcher: launcher,
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "saf", mode: .global))
        try await items[0].primaryAction?.run()
        #expect(launcher.openedApplications.map(\.path) == ["/Applications/Safari.app"])
        #expect(usage.record(for: "/Applications/Safari.app")?.count == 1)
    }

    @Test func disabledProviderReturnsNoItems() async {
        let defaultsName = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setProviderEnabled("app", to: false)
        let index = AppIndex(scanner: AppScanner(roots: []))
        index.setAppsForTesting([makeEntry("Safari", path: "/Applications/Safari.app")])
        let provider = AppProvider(
            index: index,
            settings: settings,
            usage: UsageStore(defaults: defaults),
            launcher: MockAppLauncher(),
            feedback: MockFeedback()
        )

        let items = await provider.search(SearchContext(rawQuery: "saf", mode: .global))
        #expect(items.isEmpty)
    }
}
```

测试需要 `AppIndex` 的测试注入方法。在 `AppIndex` 中增加（internal，配合 `@testable`，不进入公开 API）：

```swift
func setAppsForTesting(_ apps: [AppEntry]) {
    self.apps = apps
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make test`
Expected: `AppProvider` 与 `SystemServices` 不存在。

- [ ] **Step 3: 实现系统服务**

`Sources/DontsToolCore/Services/SystemServices.swift`：

```swift
import AppKit

@MainActor
public final class SystemAppLauncher: AppLaunching {
    public init() {}

    public func openApplication(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func openFile(at url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw ActionError.openFailed(url.lastPathComponent)
        }
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

@MainActor
public final class SystemClipboard: ClipboardProviding {
    public init() {}

    public func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    public func writeString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

@MainActor
public final class SystemURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw ActionError.openFailed(url.absoluteString)
        }
    }
}
```

- [ ] **Step 4: 实现 AppProvider**

`Sources/DontsToolCore/Providers/AppProvider.swift`：

```swift
import Foundation

@MainActor
public final class AppProvider: ToolProvider {
    public let id = ProviderID.app.rawValue
    public let displayName = "应用"
    public let keywords: [String] = []
    public let priority = 100
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }

    private let index: AppIndex
    private let settings: SettingsStore
    private let usage: UsageStore
    private let launcher: AppLaunching
    private let feedback: FeedbackProviding

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        index: AppIndex,
        settings: SettingsStore,
        usage: UsageStore,
        launcher: AppLaunching,
        feedback: FeedbackProviding
    ) {
        self.index = index
        self.settings = settings
        self.usage = usage
        self.launcher = launcher
        self.feedback = feedback
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard case .global = context.mode, isEnabled else { return [] }
        if context.query.isEmpty {
            return commonApps().enumerated().map { offset, entry in
                makeItem(entry, score: 1000 - Double(offset))
            }
        }

        let scored = index.apps.compactMap { entry -> (AppEntry, Double)? in
            guard let match = FuzzyMatcher.score(query: context.query, candidate: entry.displayName) else {
                return nil
            }
            return (entry, match + usage.boost(for: entry.id))
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.displayName.localizedStandardCompare($1.0.displayName) == .orderedAscending
        }
        .prefix(8)

        return scored.map { makeItem($0.0, score: $0.1) }
    }

    private func commonApps() -> [AppEntry] {
        var seen: Set<String> = []
        var result: [AppEntry] = []
        let byID = Dictionary(uniqueKeysWithValues: index.apps.map { ($0.id, $0) })

        for key in usage.topKeys(limit: 32) {
            guard let entry = byID[key], seen.insert(entry.id).inserted else { continue }
            result.append(entry)
            if result.count == 8 { return result }
        }

        for entry in index.apps where seen.insert(entry.id).inserted {
            result.append(entry)
            if result.count == 8 { break }
        }
        return result
    }

    private func makeItem(_ entry: AppEntry, score: Double) -> SearchItem {
        let launcher = self.launcher
        let usage = self.usage
        let feedback = self.feedback
        let key = entry.id

        return SearchItem(
            providerID: id,
            group: .app,
            title: entry.displayName,
            subtitle: PathDisplay.parentDirectory(of: entry.url),
            icon: .application(path: entry.url.path),
            score: score,
            canonicalKey: key,
            actions: [
                ItemAction(id: "app.open", title: "打开") {
                    do {
                        try await launcher.openApplication(at: entry.url)
                        usage.recordUse(of: key)
                    } catch {
                        feedback.show("无法打开应用")
                        Log.provider.error("打开应用失败: \(entry.url.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
                    }
                },
                ItemAction(id: "app.reveal", title: "在 Finder 中显示") {
                    launcher.revealInFinder(entry.url)
                }
            ]
        )
    }
}
```

- [ ] **Step 5: 运行测试**

Run: `make test`
Expected: `AppProviderTests` 通过。

---

### Task 7: 热键、面板、搜索框与结果列表

**Files:**
- Create: `Sources/DontsTool/Shell/HotKeyManager.swift`
- Create: `Sources/DontsTool/Shell/LauncherPanel.swift`
- Create: `Sources/DontsTool/Shell/SearchField.swift`
- Create: `Sources/DontsTool/Shell/ResultListViewController.swift`
- Create: `Sources/DontsTool/Shell/IconLoader.swift`

**Interfaces:**
- Consumes: `SettingsStore.HotKeyConfiguration`、`SearchItem`、`ItemIcon`
- Produces:
  - `HotKeyManager.register(_:) throws`、`onHotKey`
  - `LauncherPanel`（可成为 key window）
  - `SearchField` 键盘回调
  - `ResultListViewController.update(items:)`、`moveSelection(by:)`、`selectedItem`
  - `IconLoader.icon(for:)`

- [ ] **Step 1: 实现 Carbon 热键**

`Sources/DontsTool/Shell/HotKeyManager.swift`：

```swift
import Carbon
import DontsToolCore
import Foundation

@MainActor
final class HotKeyManager {
    enum HotKeyError: LocalizedError {
        case installHandlerFailed(OSStatus)
        case registerFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .installHandlerFailed(let status): "无法安装热键处理器（\(status)）"
            case .registerFailed(let status): "热键注册失败（\(status)），可能已被其他应用占用"
            }
        }
    }

    var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handlerInstalled = false

    // HotKeyManager 与 App 同生命周期；不实现 deinit，避免在非隔离析构中访问 Carbon 句柄。

    func register(_ configuration: SettingsStore.HotKeyConfiguration) throws {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if !handlerInstalled {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else { return noErr }
                    var identifier = EventHotKeyID()
                    let result = GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &identifier
                    )
                    guard result == noErr else { return result }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in
                        manager.onHotKey?()
                    }
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
            guard status == noErr else {
                throw HotKeyError.installHandlerFailed(status)
            }
            handlerInstalled = true
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4454_4F4C), id: 1)
        let status = RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            throw HotKeyError.registerFailed(status)
        }
    }
}
```

实现取舍：`deinit` 在 `@MainActor` 类中访问 Carbon 句柄会触发 Swift 6 并发检查（非隔离析构不能触碰 actor 隔离状态），因此按上面的应急方案删除 `deinit`。`HotKeyManager` 由 `AppController` 持有并与 App 同生命周期，进程退出时系统会回收 Carbon 热键注册，不存在实际泄漏。

- [ ] **Step 2: 实现面板与搜索框**

`Sources/DontsTool/Shell/LauncherPanel.swift`：

```swift
import AppKit

final class LauncherPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

`Sources/DontsTool/Shell/SearchField.swift`：

说明：`NSSearchField` 的编辑实际由字段编辑器（`NSTextView`）承载，方向键/回车/Esc 会以 `doCommandBy` 命令送达 delegate，而不是全部经过 `keyDown(with:)`；Cmd+, / Cmd+R 需要在 `performKeyEquivalent` 中拦截，否则会被系统菜单处理。中文输入法组合期间（`hasMarkedText()`）必须放行所有按键与文本变更，才能让候选框正常工作。

```swift
import AppKit

final class SearchField: NSSearchField, NSSearchFieldDelegate {
    var onTextChange: ((String) -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onSecondaryConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRescan: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        placeholderString = "搜索应用、文件或输入关键词…"
        font = .systemFont(ofSize: 18)
        sendsWholeSearchString = false
        sendsSearchStringImmediately = true
        focusRingType = .none
        setAccessibilityLabel("搜索")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case ",":
            onOpenSettings?()
            return true
        case "r":
            onRescan?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if isComposing {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 126:
            onMoveUp?()
        case 125:
            onMoveDown?()
        case 36:
            if event.modifierFlags.contains(.command) {
                onSecondaryConfirm?()
            } else {
                onConfirm?()
            }
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if isComposing { return }
        onTextChange?(stringValue)
    }

    private var isComposing: Bool {
        (currentEditor() as? NSTextView)?.hasMarkedText() == true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            onMoveUp?()
            return true
        case #selector(NSResponder.moveDown(_:)):
            onMoveDown?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                onSecondaryConfirm?()
            } else {
                onConfirm?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}
```

- [ ] **Step 3: 实现图标缓存与结果列表**

`Sources/DontsTool/Shell/IconLoader.swift`：

```swift
import AppKit
import DontsToolCore

@MainActor
final class IconLoader {
    static let shared = IconLoader()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for icon: ItemIcon) -> NSImage? {
        let key: NSString
        switch icon {
        case .application(let path), .file(let path):
            key = "file:\(path)" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: 32, height: 32)
            cache.setObject(image, forKey: key)
            return image
        case .symbol(let name):
            key = "symbol:\(name)" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            if let image { cache.setObject(image, forKey: key) }
            return image
        }
    }
}
```

`Sources/DontsTool/Shell/ResultListViewController.swift`：

```swift
import AppKit
import DontsToolCore

@MainActor
final class ResultListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onExecutePrimary: ((SearchItem) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "没有找到结果")
    private(set) var items: [SearchItem] = []

    var selectedItem: SearchItem? {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return nil }
        return items[row]
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.action = #selector(tableClicked)
        tableView.target = self
        tableView.setAccessibilityLabel("搜索结果")
        tableView.refusesFirstResponder = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    func update(items: [SearchItem], showEmptyState: Bool) {
        self.items = items
        emptyLabel.isHidden = !items.isEmpty || !showEmptyState
        tableView.reloadData()
        if items.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = tableView.selectedRow
        let base = current < 0 ? 0 : current
        let next = min(max(base + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ResultRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ResultRowView)
            ?? ResultRowView(identifier: identifier)
        cell.configure(with: items[row])
        return cell
    }

    @objc private func tableClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        onExecutePrimary?(items[row])
    }
}

@MainActor
private final class ResultRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        actionLabel.font = .systemFont(ofSize: 11)
        actionLabel.textColor = .tertiaryLabelColor
        actionLabel.alignment = .right
        actionLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(actionLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionLabel.leadingAnchor, constant: -12),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionLabel.leadingAnchor, constant: -12),

            actionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with item: SearchItem) {
        iconView.image = IconLoader.shared.icon(for: item.icon)
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle ?? ""
        subtitleLabel.isHidden = item.subtitle == nil
        actionLabel.stringValue = item.primaryAction?.title ?? ""
        setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: "，"))
    }
}
```

- [ ] **Step 4: 构建**

Run: `make app`
Expected: 编译通过。此时还没有把面板接到热键，无法交互验证；下一任务完成接线。

---

### Task 8: 面板控制器、菜单栏、接线与 M1 验收

**Files:**
- Create: `Sources/DontsTool/Shell/ToastPresenter.swift`
- Create: `Sources/DontsTool/Shell/LauncherPanelController.swift`
- Modify: `Sources/DontsTool/App/AppController.swift`
- Modify: `Sources/DontsTool/App/MenuBarController.swift`
- Modify: `Sources/DontsTool/App/AppDelegate.swift`

**Interfaces:**
- Consumes: Task 1–7 全部
- Produces: 可用的 M1 App：热键呼出、应用搜索、回车启动、Esc/失焦隐藏、焦点恢复、Cmd+R 重扫、`--show-panel`。

- [ ] **Step 1: 实现 Toast 与面板控制器**

`Sources/DontsTool/Shell/ToastPresenter.swift`：

```swift
import AppKit
import DontsToolCore

@MainActor
final class ToastPresenter: FeedbackProviding {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String) {
        hideTask?.cancel()

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10)
        ])

        let size = effect.fittingSize
        let toast = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.level = .statusBar
        toast.ignoresMouseEvents = true
        toast.collectionBehavior = [.canJoinAllSpaces, .transient]
        toast.contentView = effect

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            toast.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.minY + 64
            ))
        }
        toast.orderFrontRegardless()
        panel?.orderOut(nil)
        panel = toast

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}
```

`Sources/DontsTool/Shell/LauncherPanelController.swift`：

```swift
import AppKit
import DontsToolCore

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    var onOpenSettings: (() -> Void)?
    var onRescanApps: (() -> Void)?

    private let coordinator: SearchCoordinator
    private let toast: FeedbackProviding
    private let panel: LauncherPanel
    private let searchField = SearchField()
    private let resultList = ResultListViewController()
    private let statusLabel = NSTextField(labelWithString: "")
    private var previousApp: NSRunningApplication?
    private var isVisible = false

    init(coordinator: SearchCoordinator, toast: FeedbackProviding) {
        self.coordinator = coordinator
        self.toast = toast
        panel = LauncherPanel(size: NSSize(width: 640, height: 420))
        super.init()
        buildContent()
        panel.delegate = self
        coordinator.onUpdate = { [weak self] update in
            self?.render(update)
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }
        positionPanel()

        searchField.stringValue = ""
        isVisible = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        refreshSearch()
    }

    func hide(restorePreviousApp: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
        if restorePreviousApp {
            previousApp?.activate()
        }
        previousApp = nil
    }

    func refreshSearch() {
        let bundleID = previousApp?.bundleIdentifier
        coordinator.submit(searchField.stringValue, frontmostBundleID: bundleID)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        hide()
    }

    private func buildContent() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        panel.contentView = root

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onTextChange = { [weak self] _ in self?.refreshSearch() }
        searchField.onMoveUp = { [weak self] in self?.resultList.moveSelection(by: -1) }
        searchField.onMoveDown = { [weak self] in self?.resultList.moveSelection(by: 1) }
        searchField.onConfirm = { [weak self] in self?.execute(secondary: false) }
        searchField.onSecondaryConfirm = { [weak self] in self?.execute(secondary: true) }
        searchField.onCancel = { [weak self] in self?.hide() }
        searchField.onOpenSettings = { [weak self] in
            self?.hide(restorePreviousApp: false)
            self?.onOpenSettings?()
        }
        searchField.onRescan = { [weak self] in self?.onRescanApps?() }

        resultList.onExecutePrimary = { [weak self] item in
            self?.execute(item: item, secondary: false)
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let hints = NSTextField(labelWithString: "↑↓ 选择   ↵ 执行   esc 关闭")
        hints.font = .systemFont(ofSize: 11)
        hints.textColor = .tertiaryLabelColor
        hints.translatesAutoresizingMaskIntoConstraints = false

        let listView = resultList.view
        listView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(separator)
        root.addSubview(listView)
        root.addSubview(statusLabel)
        root.addSubview(hints)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.heightAnchor.constraint(equalToConstant: 38),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),

            listView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            listView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),
            hints.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hints.bottomAnchor.constraint(equalTo: statusLabel.bottomAnchor)
        ])
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * 0.18 - size.height
        )
        panel.setFrameOrigin(origin)
    }

    private func render(_ update: SearchCoordinator.Update) {
        resultList.update(items: update.items, showEmptyState: update.status != .searchingFiles)
        switch update.status {
        case .idle:
            statusLabel.stringValue = ""
        case .searchingFiles:
            statusLabel.stringValue = "正在搜索文件…"
        case .message(let message):
            statusLabel.stringValue = message
        }
    }

    private func execute(secondary: Bool) {
        guard let item = resultList.selectedItem else { return }
        execute(item: item, secondary: secondary)
    }

    private func execute(item: SearchItem, secondary: Bool) {
        guard let action = secondary ? item.secondaryAction : item.primaryAction else { return }
        switch action.presentation {
        case .dismissThenRun:
            hide()
            Task { @MainActor in
                do {
                    try await action.run()
                } catch {
                    toast.show(error.localizedDescription)
                }
            }
        case .keepPanelUntilComplete:
            Task { @MainActor in
                do {
                    try await action.run()
                    self.hide()
                } catch {
                    toast.show(error.localizedDescription)
                }
            }
        case .keepPanelOpen:
            Task { @MainActor in
                do {
                    try await action.run()
                } catch {
                    toast.show(error.localizedDescription)
                }
            }
        }
    }
}
```

- [ ] **Step 2: 接线 AppController**

`Sources/DontsTool/App/AppController.swift` 替换为：

```swift
import AppKit
import DontsToolCore

@MainActor
final class AppController {
    private let settings = SettingsStore()
    private let usage = UsageStore()
    private let appIndex = AppIndex()
    private let hotKeyManager = HotKeyManager()
    private let toast = ToastPresenter()
    private var menuBar: MenuBarController?
    private var panel: LauncherPanelController?
    private var coordinator: SearchCoordinator?

    func start() {
        let launcher = SystemAppLauncher()
        let appProvider = AppProvider(
            index: appIndex,
            settings: settings,
            usage: usage,
            launcher: launcher,
            feedback: toast
        )
        let registry = ToolRegistry(providers: [appProvider])
        let coordinator = SearchCoordinator(registry: registry)
        let panel = LauncherPanelController(coordinator: coordinator, toast: toast)
        panel.onRescanApps = { [weak self] in
            self?.rescanApps()
        }
        self.coordinator = coordinator
        self.panel = panel

        let menuBar = MenuBarController()
        menuBar.onOpenLauncher = { [weak panel] in panel?.toggle() }
        menuBar.onRescanApps = { [weak self] in self?.rescanApps() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.hotKeyDisplay = HotKeyFormatter.displayString(for: settings.hotKey)
        menuBar.install()
        self.menuBar = menuBar

        hotKeyManager.onHotKey = { [weak panel] in panel?.toggle() }
        do {
            try hotKeyManager.register(settings.hotKey)
        } catch {
            Log.app.error("全局热键注册失败: \(error.localizedDescription, privacy: .public)")
        }

        Task {
            await appIndex.scan()
            panel.refreshSearch()
        }

        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak panel] in
                panel?.show()
            }
        }
    }

    func shutdown() {
        usage.flush()
    }

    private func rescanApps() {
        Task { @MainActor in
            await appIndex.scan()
            toast.show("已索引 \(appIndex.apps.count) 个应用")
            panel?.refreshSearch()
        }
    }
}
```

`MenuBarController` 增加 `onOpenLauncher`、`onRescanApps`、`hotKeyDisplay`，菜单项为：

```swift
import AppKit

@MainActor
final class MenuBarController: NSObject {
    var onOpenLauncher: (() -> Void)?
    var onRescanApps: (() -> Void)?
    var onQuit: (() -> Void)?
    var hotKeyDisplay = "⌥Space"

    private var statusItem: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "DontsTool")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "DontsTool（\(hotKeyDisplay)）"

        let menu = NSMenu()
        let open = NSMenuItem(title: "打开启动器", action: #selector(openLauncher), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let rescan = NSMenuItem(title: "重新扫描应用", action: #selector(rescanApps), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 DontsTool", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func openLauncher() { onOpenLauncher?() }
    @objc private func rescanApps() { onRescanApps?() }
    @objc private func quit() { onQuit?() }
}
```

- [ ] **Step 3: 构建并运行**

Run:

```bash
make test
make run ARGS=--show-panel
```

Expected:
- 面板在鼠标所在屏幕顶部约 18% 处出现，搜索框获得焦点。
- 空查询显示常用应用（首次按名称排序）。
- 输入 `chr` 可在前几条看到 Chrome 类应用；回车启动，面板关闭。
- Esc、再次按 `⌥Space`、点击面板外都会隐藏。
- 隐藏后此前前台应用恢复。
- 菜单栏“重新扫描应用”有 Toast，索引数量刷新。

- [ ] **Step 4: 截图验证**

Run:

```bash
screencapture -x /tmp/dontstool-m1.png
```

然后读取 `/tmp/dontstool-m1.png` 检查面板外观、圆角、模糊背景、列表行与底部提示。若系统未授权终端录屏，记录“无法自动截图，需人工确认”，并继续用 `--show-panel` 手动验证。

---

## M2：扩展模型与轻工具

### Task 9: 文本转换引擎

**Files:**
- Create: `Sources/DontsToolCore/Providers/TextTransformers.swift`
- Test: `Tests/DontsToolCoreTests/TextTransformersTests.swift`

**Interfaces:**
- Consumes: `CryptoKit`
- Produces:
  - `TextTransformers.formatJSON(_:pretty:)`
  - `base64Encode` / `base64Decode`
  - `urlEncode` / `urlDecode`
  - `transformTimestamp(_:now:timeZone:)` → `TimestampConversion`
  - `hash(_:algorithm:)`
  - `HashAlgorithm` / `TimestampConversion`

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
@testable import DontsToolCore

@Suite("TextTransformers")
struct TextTransformersTests {
    @Test func jsonPrettyAndMinify() throws {
        let pretty = try TextTransformers.formatJSON(#"{"b":2,"a":1}"#, pretty: true)
        #expect(pretty.contains("\n"))
        #expect(pretty.contains("\"a\""))
        let minified = try TextTransformers.formatJSON(#"{"b":2,"a":1}"#, pretty: false)
        #expect(!minified.contains("\n"))
    }

    @Test func invalidJSONThrows() {
        #expect(throws: (any Error).self) {
            try TextTransformers.formatJSON("not json", pretty: true)
        }
    }

    @Test func base64RoundTrip() throws {
        let encoded = TextTransformers.base64Encode("hello")
        #expect(encoded == "aGVsbG8=")
        #expect(try TextTransformers.base64Decode(encoded) == "hello")
    }

    @Test func invalidBase64Throws() {
        #expect(throws: (any Error).self) {
            try TextTransformers.base64Decode("***")
        }
    }

    @Test func urlEncodeUsesRFC3986() throws {
        #expect(try TextTransformers.urlEncode("a b") == "a%20b")
        #expect(try TextTransformers.urlDecode("a%20b") == "a b")
        #expect(try TextTransformers.urlEncode("中") == "%E4%B8%AD")
    }

    @Test func timestampSecondsAndMilliseconds() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let seconds = try TextTransformers.transformTimestamp("1700000000", now: Date(), timeZone: utc)
        #expect(seconds.output == "2023-11-14 22:13:20")
        let milliseconds = try TextTransformers.transformTimestamp("1700000000000", now: Date(), timeZone: utc)
        #expect(milliseconds.output == "2023-11-14 22:13:20")
    }

    @Test func dateStringConvertsToTimestamp() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let result = try TextTransformers.transformTimestamp("2023-11-14 22:13:20", now: Date(), timeZone: utc)
        #expect(result.output == "1700000000")
    }

    @Test func hashKnownVectors() {
        #expect(TextTransformers.hash("hello", algorithm: .md5) == "5d41402abc4b2a76b9719d911017c592")
        #expect(TextTransformers.hash("hello", algorithm: .sha1) == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
        #expect(TextTransformers.hash("hello", algorithm: .sha256) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make test`
Expected: `TextTransformers` 不存在。

- [ ] **Step 3: 实现转换**

```swift
import CryptoKit
import Foundation

public enum HashAlgorithm: String, CaseIterable, Sendable {
    case md5
    case sha1
    case sha256

    public var displayName: String {
        rawValue.uppercased()
    }
}

public struct TimestampConversion: Sendable {
    public let title: String
    public let output: String
    public let subtitle: String

    public init(title: String, output: String, subtitle: String) {
        self.title = title
        self.output = output
        self.subtitle = subtitle
    }
}

public enum TextTransformers {
    public static func formatJSON(_ input: String, pretty: Bool) throws -> String {
        let data = Data(input.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ActionError.invalidInput("不是有效的 JSON")
        }

        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        do {
            let output = try JSONSerialization.data(withJSONObject: object, options: options)
            guard let string = String(data: output, encoding: .utf8) else {
                throw ActionError.invalidInput("JSON 输出不是 UTF-8 文本")
            }
            return string
        } catch {
            throw ActionError.invalidInput("无法序列化 JSON")
        }
    }

    public static func base64Encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    public static func base64Decode(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let string = String(data: data, encoding: .utf8) else {
            throw ActionError.invalidInput("不是有效的 Base64 文本")
        }
        return string
    }

    public static func urlEncode(_ input: String) throws -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = input.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ActionError.invalidInput("URL 编码失败")
        }
        return encoded
    }

    public static func urlDecode(_ input: String) throws -> String {
        guard let decoded = input.removingPercentEncoding else {
            throw ActionError.invalidInput("不是有效的百分号编码")
        }
        return decoded
    }

    public static func transformTimestamp(
        _ input: String,
        now: Date,
        timeZone: TimeZone = .current
    ) throws -> TimestampConversion {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let timestamp = String(Int(now.timeIntervalSince1970))
            return TimestampConversion(
                title: "当前时间",
                output: timestamp,
                subtitle: displayFormatter(timeZone: timeZone).string(from: now)
            )
        }

        if trimmed.allSatisfy(\.isNumber) {
            let seconds: TimeInterval
            if trimmed.count == 10 {
                seconds = TimeInterval(trimmed) ?? 0
            } else if trimmed.count == 13 {
                seconds = (TimeInterval(trimmed) ?? 0) / 1000
            } else {
                throw ActionError.invalidInput("时间戳应为 10 位秒或 13 位毫秒")
            }
            let date = Date(timeIntervalSince1970: seconds)
            let display = displayFormatter(timeZone: timeZone).string(from: date)
            return TimestampConversion(title: trimmed, output: display, subtitle: "时间戳转日期")
        }

        if let date = parseDate(trimmed, timeZone: timeZone) {
            let timestamp = String(Int(date.timeIntervalSince1970))
            return TimestampConversion(title: trimmed, output: timestamp, subtitle: "日期转时间戳")
        }

        throw ActionError.invalidInput("无法识别的时间；支持 10/13 位时间戳或 yyyy-MM-dd HH:mm:ss")
    }

    public static func hash(_ input: String, algorithm: HashAlgorithm) -> String {
        let data = Data(input.utf8)
        let digest: [UInt8]
        switch algorithm {
        case .md5:
            digest = Array(Insecure.MD5.hash(data: data))
        case .sha1:
            digest = Array(Insecure.SHA1.hash(data: data))
        case .sha256:
            digest = Array(SHA256.hash(data: data))
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func displayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    private static func parseDate(_ input: String, timeZone: TimeZone) -> Date? {
        let formatter = displayFormatter(timeZone: timeZone)
        if let date = formatter.date(from: input) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: input) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: input)
    }
}
```

- [ ] **Step 4: 运行测试**

Run: `make test`
Expected: 文本转换测试全部通过。

---

### Task 10: TextToolsProvider 与工具提示

**Files:**
- Create: `Sources/DontsToolCore/Providers/TextToolsProvider.swift`
- Test: `Tests/DontsToolCoreTests/TextToolsProviderTests.swift`

**Interfaces:**
- Consumes: `TextTransformers`、`ClipboardProviding`、`FeedbackProviding`、`QueryPrefilling`、`ActionPresentation`、`SettingsStore`
- Produces: `TextToolsProvider`（keywords `json`、`b64`、`b64d`、`url`、`urld`、`ts`、`uuid`、`md5`、`sha1`、`sha256`；priority 200；fast）。

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
@testable import DontsToolCore

// MockClipboard、MockPrefiller 定义在 Mocks.swift；MockFeedback 定义在 AppProviderTests.swift。
// 同一个测试 target 共用这些 mock，避免重复声明。

@Suite("TextToolsProvider")
@MainActor
struct TextToolsProviderTests {
    private func makeProvider() -> (TextToolsProvider, MockClipboard, MockFeedback, MockPrefiller) {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let clipboard = MockClipboard()
        let feedback = MockFeedback()
        let prefill = MockPrefiller()
        return (
            TextToolsProvider(
                settings: settings,
                clipboard: clipboard,
                feedback: feedback,
                prefill: prefill
            ),
            clipboard,
            feedback,
            prefill
        )
    }

    @Test func jsonKeywordShowsPreviewAndCopies() async throws {
        let (provider, clipboard, feedback, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "json {\"a\":1}",
            mode: .keyword(providerID: "text", keyword: "json", argument: #"{"a":1}"#)
        )
        let items = await provider.search(context)
        #expect(items.count == 1)
        #expect(items[0].title.contains("\"a\""))

        try await items[0].primaryAction?.run()
        #expect(clipboard.written.first?.contains("\"a\"") == true)
        #expect(feedback.messages == ["已复制到剪贴板"])
    }

    @Test func emptyArgumentReadsClipboardAtExecution() async throws {
        let (provider, clipboard, _, _) = makeProvider()
        clipboard.value = "hello"
        let context = SearchContext(
            rawQuery: "b64",
            mode: .keyword(providerID: "text", keyword: "b64", argument: "")
        )
        let items = await provider.search(context)
        #expect(clipboard.written.isEmpty)
        try await items[0].primaryAction?.run()
        #expect(clipboard.written.first == "aGVsbG8=")
    }

    @Test func invalidJSONReportsReadableError() async {
        let (provider, _, _, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "json nope",
            mode: .keyword(providerID: "text", keyword: "json", argument: "nope")
        )
        let items = await provider.search(context)
        #expect(items[0].subtitle == "不是有效的 JSON")
    }

    @Test func uuidHasValidShape() async {
        let (provider, _, _, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "uuid",
            mode: .keyword(providerID: "text", keyword: "uuid", argument: "")
        )
        let items = await provider.search(context)
        let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
        #expect(items[0].title.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test func emptyQueryReturnsHintsThatPrefill() async throws {
        let (provider, _, _, prefill) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(items.count == 6)
        try await items[0].primaryAction?.run()
        #expect(prefill.queries.first?.hasSuffix(" ") == true)
    }

    @Test func globalNonEmptyQueryReturnsNothing() async {
        let (provider, _, _, _) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "chrome", mode: .global))
        #expect(items.isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make test`
Expected: `TextToolsProvider` 不存在。

- [ ] **Step 3: 实现 Provider**

```swift
import Foundation

@MainActor
public final class TextToolsProvider: ToolProvider {
    public let id = ProviderID.text.rawValue
    public let displayName = "文本工具"
    public let keywords = ["json", "b64", "b64d", "url", "urld", "ts", "uuid", "md5", "sha1", "sha256"]
    public let priority = 200
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }

    private let settings: SettingsStore
    private let clipboard: ClipboardProviding
    private let feedback: FeedbackProviding
    private let prefill: QueryPrefilling

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        settings: SettingsStore,
        clipboard: ClipboardProviding,
        feedback: FeedbackProviding,
        prefill: QueryPrefilling
    ) {
        self.settings = settings
        self.clipboard = clipboard
        self.feedback = feedback
        self.prefill = prefill
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled else { return [] }

        switch context.mode {
        case .keyword(let providerID, let keyword, _) where providerID == id:
            return [keywordItem(keyword: keyword, argument: context.query)]
        case .global where context.query.isEmpty:
            return hints()
        default:
            return []
        }
    }

    private func hints() -> [SearchItem] {
        let definitions: [(keyword: String, title: String, symbol: String)] = [
            ("json", "格式化 JSON", "curlybraces"),
            ("b64", "Base64 编码", "textformat.abc"),
            ("url", "URL 编码", "link"),
            ("ts", "时间戳转换", "clock"),
            ("uuid", "生成 UUID", "number"),
            ("sha256", "计算哈希", "number.square")
        ]
        let prefill = self.prefill
        return definitions.enumerated().map { offset, definition in
            SearchItem(
                providerID: id,
                group: .tool,
                title: definition.title,
                subtitle: "输入 \(definition.keyword) + 内容",
                icon: .symbol(name: definition.symbol),
                score: 1000 - Double(offset),
                canonicalKey: "hint:\(definition.keyword)",
                actions: [
                    ItemAction(id: "text.prefill", title: "填入关键词", presentation: .keepPanelOpen) {
                        prefill.prefill(definition.keyword + " ")
                    }
                ]
            )
        }
    }

    private func keywordItem(keyword: String, argument: String) -> SearchItem {
        switch keyword {
        case "json":
            return transformationItem(
                keyword: keyword,
                argument: argument,
                label: "JSON",
                symbol: "curlybraces",
                transform: { try TextTransformers.formatJSON($0, pretty: true) },
                secondary: ("压缩并复制", { try TextTransformers.formatJSON($0, pretty: false) })
            )
        case "b64":
            return transformationItem(keyword: keyword, argument: argument, label: "Base64 编码", symbol: "textformat.abc", transform: { TextTransformers.base64Encode($0) })
        case "b64d":
            return transformationItem(keyword: keyword, argument: argument, label: "Base64 解码", symbol: "textformat.abc.dottedunderline", transform: { try TextTransformers.base64Decode($0) })
        case "url":
            return transformationItem(keyword: keyword, argument: argument, label: "URL 编码", symbol: "link", transform: { try TextTransformers.urlEncode($0) })
        case "urld":
            return transformationItem(keyword: keyword, argument: argument, label: "URL 解码", symbol: "link.badge.plus", transform: { try TextTransformers.urlDecode($0) })
        case "ts":
            return timestampItem(argument: argument)
        case "uuid":
            return uuidItem()
        case "md5", "sha1", "sha256":
            let algorithm = HashAlgorithm(rawValue: keyword)!
            return transformationItem(
                keyword: keyword,
                argument: argument,
                label: "\(algorithm.displayName) 哈希",
                symbol: "number.square",
                transform: { TextTransformers.hash($0, algorithm: algorithm) }
            )
        default:
            return SearchItem(
                providerID: id,
                group: .tool,
                title: "未知工具",
                icon: .symbol(name: "questionmark"),
                score: 0,
                canonicalKey: "unknown:\(keyword)",
                actions: []
            )
        }
    }

    private func transformationItem(
        keyword: String,
        argument: String,
        label: String,
        symbol: String,
        transform: @escaping (String) throws -> String,
        secondary: (title: String, transform: (String) throws -> String)? = nil
    ) -> SearchItem {
        let clipboard = self.clipboard
        let feedback = self.feedback
        let usesClipboard = argument.isEmpty

        let result: Result<String, Error>? = usesClipboard ? nil : Result { try transform(argument) }
        let preview = result.flatMap { try? $0.get() }.map { summarize($0) }
        let errorMessage = result.flatMap { result -> String? in
            if case .failure(let error) = result { return error.localizedDescription }
            return nil
        }

        var actions: [ItemAction] = []
        actions.append(ItemAction(id: "text.primary", title: "复制结果") {
            let input: String
            if usesClipboard {
                guard let clipboardValue = clipboard.readString(), !clipboardValue.isEmpty else {
                    throw ActionError.clipboardEmpty
                }
                input = clipboardValue
            } else {
                input = argument
            }
            let output = try transform(input)
            clipboard.writeString(output)
            feedback.show("已复制到剪贴板")
        })

        if let secondary {
            actions.append(ItemAction(id: "text.secondary", title: secondary.title) {
                let input: String
                if usesClipboard {
                    guard let clipboardValue = clipboard.readString(), !clipboardValue.isEmpty else {
                        throw ActionError.clipboardEmpty
                    }
                    input = clipboardValue
                } else {
                    input = argument
                }
                let output = try secondary.transform(input)
                clipboard.writeString(output)
                feedback.show("已复制到剪贴板")
            })
        }

        if let errorMessage {
            let action = actions[0]
            actions[0] = ItemAction(id: action.id, title: action.title, presentation: action.presentation) {
                throw ActionError.invalidInput(errorMessage)
            }
        }

        return SearchItem(
            providerID: id,
            group: .tool,
            title: preview ?? (usesClipboard ? "\(label)剪贴板内容" : "\(label)失败"),
            subtitle: errorMessage ?? (usesClipboard ? "从剪贴板读取" : "回车复制"),
            icon: .symbol(name: symbol),
            score: 1000,
            canonicalKey: "\(keyword):\(argument)",
            actions: actions
        )
    }

    private func timestampItem(argument: String) -> SearchItem {
        let clipboard = self.clipboard
        let feedback = self.feedback
        switch Result(catching: { try TextTransformers.transformTimestamp(argument, now: Date()) }) {
        case .success(let conversion):
            return SearchItem(
                providerID: id,
                group: .tool,
                title: conversion.output,
                subtitle: conversion.subtitle,
                icon: .symbol(name: "clock"),
                score: 1000,
                canonicalKey: "ts:\(argument)",
                actions: [
                    ItemAction(id: "text.copy", title: "复制结果") {
                        clipboard.writeString(conversion.output)
                        feedback.show("已复制到剪贴板")
                    }
                ]
            )
        case .failure(let error):
            return SearchItem(
                providerID: id,
                group: .tool,
                title: "时间戳转换失败",
                subtitle: error.localizedDescription,
                icon: .symbol(name: "clock.badge.exclamationmark"),
                score: 1000,
                canonicalKey: "ts:\(argument)",
                actions: [
                    ItemAction(id: "text.error", title: "复制结果") {
                        throw error
                    }
                ]
            )
        }
    }

    private func uuidItem() -> SearchItem {
        let value = UUID().uuidString.lowercased()
        let clipboard = self.clipboard
        let feedback = self.feedback
        return SearchItem(
            providerID: id,
            group: .tool,
            title: value,
            subtitle: "UUID v4 · 回车复制",
            icon: .symbol(name: "number"),
            score: 1000,
            canonicalKey: "uuid:\(value)",
            actions: [
                ItemAction(id: "text.copy", title: "复制结果") {
                    clipboard.writeString(value)
                    feedback.show("已复制到剪贴板")
                }
            ]
        )
    }

    private func summarize(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 80 { return singleLine }
        return String(singleLine.prefix(80)) + "…"
    }
}
```

- [ ] **Step 4: 运行测试**

Run: `make test`
Expected: `TextToolsProviderTests` 通过。

---

### Task 11: WebSearchProvider

**Files:**
- Create: `Sources/DontsToolCore/Providers/WebSearchProvider.swift`
- Test: `Tests/DontsToolCoreTests/WebSearchProviderTests.swift`

**Interfaces:**
- Consumes: `SettingsStore`、`UsageStore`、`URLOpening`、`FeedbackProviding`、`QueryPrefilling`、`ProviderID`
- Produces: `WebSearchProvider`（keywords `g`、`bing`、`bd`、`ddg`、`gh`；priority 150；fast；全局兜底项）。

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
@testable import DontsToolCore

@MainActor
final class MockURLOpener: URLOpening {
    var opened: [URL] = []
    var error: Error?
    func open(_ url: URL) throws {
        if let error { throw error }
        opened.append(url)
    }
}

@Suite("WebSearchProvider")
@MainActor
struct WebSearchProviderTests {
    private func makeProvider() -> (WebSearchProvider, SettingsStore, MockURLOpener, MockPrefiller) {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        let opener = MockURLOpener()
        let prefill = MockPrefiller()
        let provider = WebSearchProvider(
            settings: settings,
            usage: UsageStore(defaults: defaults),
            opener: opener,
            feedback: MockFeedback(),
            prefill: prefill
        )
        return (provider, settings, opener, prefill)
    }

    @Test func keywordOpensEncodedSearch() async throws {
        let (provider, _, opener, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "g swift concurrency",
            mode: .keyword(providerID: "web", keyword: "g", argument: "swift concurrency")
        )
        let items = await provider.search(context)
        #expect(items.count == 1)
        try await items[0].primaryAction?.run()

        let components = URLComponents(url: opener.opened[0], resolvingAgainstBaseURL: false)
        #expect(components?.host == "www.google.com")
        #expect(components?.queryItems == [URLQueryItem(name: "q", value: "swift concurrency")])
    }

    @Test func defaultEngineIsUsedForFallback() async throws {
        let (provider, settings, opener, _) = makeProvider()
        settings.setDefaultSearchEngine(.baidu)
        let items = await provider.search(SearchContext(rawQuery: "swift", mode: .global))
        #expect(items.count == 1)
        try await items[0].primaryAction?.run()
        #expect(URLComponents(url: opener.opened[0], resolvingAgainstBaseURL: false)?.host == "www.baidu.com")
    }

    @Test func emptyKeywordArgumentDoesNotOpenBrowser() async throws {
        let (provider, _, opener, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "g",
            mode: .keyword(providerID: "web", keyword: "g", argument: "")
        )
        let items = await provider.search(context)
        try await items[0].primaryAction?.run()
        #expect(opener.opened.isEmpty)
    }

    @Test func emptyQueryReturnsPrefillHint() async throws {
        let (provider, _, _, prefill) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(items.count == 1)
        try await items[0].primaryAction?.run()
        #expect(prefill.queries == ["g "])
    }

    @Test func githubKeywordUsesGithubSearch() async throws {
        let (provider, _, opener, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "gh swift",
            mode: .keyword(providerID: "web", keyword: "gh", argument: "swift")
        )
        let items = await provider.search(context)
        try await items[0].primaryAction?.run()
        #expect(URLComponents(url: opener.opened[0], resolvingAgainstBaseURL: false)?.host == "github.com")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make test`
Expected: `WebSearchProvider` 不存在。

- [ ] **Step 3: 实现 Provider**

```swift
import Foundation

@MainActor
public final class WebSearchProvider: ToolProvider {
    public let id = ProviderID.web.rawValue
    public let displayName = "网页搜索"
    public let keywords = ["g", "bing", "bd", "ddg", "gh"]
    public let priority = 150
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }

    private enum Target {
        case engine(SettingsStore.SearchEngine, keyword: String)
        case github
    }

    private let settings: SettingsStore
    private let usage: UsageStore
    private let opener: URLOpening
    private let feedback: FeedbackProviding
    private let prefill: QueryPrefilling

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        settings: SettingsStore,
        usage: UsageStore,
        opener: URLOpening,
        feedback: FeedbackProviding,
        prefill: QueryPrefilling
    ) {
        self.settings = settings
        self.usage = usage
        self.opener = opener
        self.feedback = feedback
        self.prefill = prefill
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled else { return [] }

        switch context.mode {
        case .keyword(let providerID, let keyword, _) where providerID == id:
            return [keywordItem(keyword: keyword, argument: context.query)]
        case .global where context.query.isEmpty:
            return [hintItem()]
        case .global:
            return [fallbackItem(query: context.query)]
        default:
            return []
        }
    }

    private func target(for keyword: String) -> Target? {
        switch keyword {
        case "g": .engine(.google, keyword: keyword)
        case "bing": .engine(.bing, keyword: keyword)
        case "bd": .engine(.baidu, keyword: keyword)
        case "ddg": .engine(.ddg, keyword: keyword)
        case "gh": .github
        default: nil
        }
    }

    private func keywordItem(keyword: String, argument: String) -> SearchItem {
        guard let target = target(for: keyword) else {
            return hintItem()
        }
        guard !argument.isEmpty else {
            let feedback = self.feedback
            return SearchItem(
                providerID: id,
                group: .tool,
                title: "输入要搜索的内容",
                subtitle: displayName(for: target),
                icon: .symbol(name: "magnifyingglass"),
                score: 1000,
                canonicalKey: "web.empty:\(keyword)",
                actions: [
                    ItemAction(id: "web.empty", title: "提示", presentation: .keepPanelOpen) {
                        feedback.show("请输入要搜索的内容")
                    }
                ]
            )
        }
        return makeWebItem(query: argument, target: target)
    }

    private func fallbackItem(query: String) -> SearchItem {
        makeWebItem(query: query, target: .engine(settings.defaultSearchEngine, keyword: "fallback"))
    }

    private func hintItem() -> SearchItem {
        let prefill = self.prefill
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "网页搜索",
            subtitle: "默认引擎：\(settings.defaultSearchEngine.displayName)",
            icon: .symbol(name: "globe"),
            score: 900,
            canonicalKey: "hint:web",
            actions: [
                ItemAction(id: "web.prefill", title: "填入关键词", presentation: .keepPanelOpen) {
                    prefill.prefill("g ")
                }
            ]
        )
    }

    private func makeWebItem(query: String, target: Target) -> SearchItem {
        let url: URL
        let title: String
        let targetName: String
        switch target {
        case .engine(let engine, _):
            guard let built = engine.searchURL(for: query) else {
                preconditionFailure("搜索引擎 URL 构造失败")
            }
            url = built
            targetName = engine.displayName
            title = "用 \(engine.displayName) 搜索 “\(query)”"
        case .github:
            var components = URLComponents()
            components.scheme = "https"
            components.host = "github.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let built = components.url else {
                preconditionFailure("GitHub URL 构造失败")
            }
            url = built
            targetName = "GitHub"
            title = "在 GitHub 搜索 “\(query)”"
        }

        let opener = self.opener
        let feedback = self.feedback
        let usage = self.usage
        let canonicalKey = url.absoluteString

        return SearchItem(
            providerID: id,
            group: .web,
            title: title,
            subtitle: "\(targetName) · 回车打开浏览器",
            icon: .symbol(name: "magnifyingglass"),
            score: 100,
            canonicalKey: canonicalKey,
            actions: [
                ItemAction(id: "web.open", title: "打开") {
                    do {
                        try opener.open(url)
                        usage.recordUse(of: canonicalKey)
                    } catch {
                        feedback.show(error.localizedDescription)
                    }
                }
            ]
        )
    }

    private func displayName(for target: Target) -> String {
        switch target {
        case .engine(let engine, _): engine.displayName
        case .github: "GitHub"
        }
    }
}
```

- [ ] **Step 4: 运行测试**

Run: `make test`
Expected: `WebSearchProviderTests` 通过。

---

### Task 12: 接线文本工具/网页搜索、空状态与 M2 验收

**Files:**
- Modify: `Sources/DontsTool/App/AppController.swift`
- Modify: `Sources/DontsTool/Shell/LauncherPanelController.swift`
- Modify: `Sources/DontsTool/Shell/SearchField.swift`（如需处理 Cmd+Enter）
- Test: 现有单元测试

**Interfaces:**
- Consumes: Task 9–11
- Produces: M2 可用功能。

- [ ] **Step 1: AppController 注册全部 Provider**

将 `start()` 开头的构造改为（panel 在 coordinator 之后创建，Provider 通过 `PanelPrefiller` 弱引用回填）：

```swift
let prefiller = PanelPrefiller()
let appProvider = AppProvider(
    index: appIndex,
    settings: settings,
    usage: usage,
    launcher: SystemAppLauncher(),
    feedback: toast
)
let textProvider = TextToolsProvider(
    settings: settings,
    clipboard: SystemClipboard(),
    feedback: toast,
    prefill: prefiller
)
let webProvider = WebSearchProvider(
    settings: settings,
    usage: usage,
    opener: SystemURLOpener(),
    feedback: toast,
    prefill: prefiller
)
let registry = ToolRegistry(providers: [appProvider, textProvider, webProvider])
let coordinator = SearchCoordinator(registry: registry)
let panel = LauncherPanelController(coordinator: coordinator, toast: toast)
prefiller.panel = panel
```

`LauncherPanelController` 实现 `QueryPrefilling`（保持方法在类扩展中）：

```swift
extension LauncherPanelController: QueryPrefilling {
    func prefill(_ query: String) {
        searchField.stringValue = query
        panel.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: query.utf16.count, length: 0)
        }
        refreshSearch()
    }
}
```

循环依赖（panel 初始化需要 coordinator，Provider 需要 prefill）用弱引用适配器解决：

```swift
@MainActor
final class PanelPrefiller: QueryPrefilling {
    weak var panel: LauncherPanelController?

    func prefill(_ query: String) {
        panel?.prefill(query)
    }
}
```

提示项（填入关键词、空参数提示）的 `ItemAction` 必须使用 `presentation: .keepPanelOpen`，否则 `dismissThenRun` 会先隐藏面板再执行预填，用户看到面板关闭而查询被写进隐藏的搜索框。`ActionPresentation` 因此有三个值：`dismissThenRun`、`keepPanelUntilComplete`、`keepPanelOpen`。

- [ ] **Step 2: 空状态与工具提示**

确认：
- 空查询时 AppProvider 返回 8 个常用应用，TextTools 返回 6 个提示，WebSearch 返回 1 个提示。
- `tool` 分组上限为 8，正好容纳 7 条提示（翻译加入后为 8）。
- 空查询不调用慢速 FileProvider。
- 结果列表无结果且不是“正在搜索文件…”时显示“没有找到结果”。

- [ ] **Step 3: 运行全部测试和手动验收**

Run:

```bash
make test
make run ARGS=--show-panel
```

手动检查：
- `json {"a":1}` 显示格式化预览，回车复制，Toast 出现。
- `json nope` 显示错误副标题，回车 Toast 相同错误。
- `b64 hello`、`b64d aGVsbG8=`、`url a b`、`ts 1700000000`、`uuid`、`sha256 hello` 输出正确。
- `g swift concurrency` 打开浏览器搜索。
- 输入无本地结果的词，出现默认引擎兜底项。
- 按 `Cmd+Enter` 对 JSON 执行压缩复制。
- 空查询的工具提示按回车可把关键词填入搜索框。

---

## M3：文件、翻译与设置

### Task 13: mdfind 文件搜索

**Files:**
- Create: `Sources/DontsToolCore/Index/FileSearchService.swift`
- Create: `Sources/DontsToolCore/Providers/FileProvider.swift`
- Test: `Tests/DontsToolCoreTests/FileSearchServiceTests.swift`

**Interfaces:**
- Consumes: `CommandRunning`、`CommandResult`、`FuzzyMatcher`、`SettingsStore`、`UsageStore`
- Produces:
  - `ProcessCommandRunner`
  - `FileSearchResult`（`paths`、`timedOut`）
  - `FileSearchService.search(query:timeout:)`
  - `FileProvider`（id `file`，phase `.slow`，statusNotice）

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
@testable import DontsToolCore

final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    var result: CommandResult!
    var error: Error?
    var receivedArguments: [String] = []

    func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult {
        receivedArguments = arguments
        if let error { throw error }
        return result
    }
}

@Suite("FileSearchService")
struct FileSearchServiceTests {
    @Test func filtersSystemHiddenAndAppPaths() async throws {
        let runner = MockCommandRunner()
        runner.result = CommandResult(
            output: """
            /Users/donts/Desktop/report.pdf
            /System/Library/foo.txt
            /Users/donts/.secret/hidden.txt
            /Users/donts/Desktop/Report.app
            /private/tmp/x.txt
            """,
            terminationStatus: 0,
            timedOut: false
        )
        let service = FileSearchService(runner: runner)
        let result = try await service.search(query: "report", timeout: .milliseconds(300))
        #expect(result.paths.map(\.lastPathComponent) == ["report.pdf"])
        #expect(runner.receivedArguments == ["-name", "report"])
    }

    @Test func ranksMatchesAndCapsAtTwelve() async throws {
        let runner = MockCommandRunner()
        let lines = (0..<20).map { "/Users/donts/Desktop/report-\($0).txt" }.joined(separator: "\n")
        runner.result = CommandResult(output: lines, terminationStatus: 0, timedOut: false)
        let service = FileSearchService(runner: runner)
        let result = try await service.search(query: "report", timeout: .milliseconds(300))
        #expect(result.paths.count == 12)
    }

    @Test func timedOutReturnsPartialResults() async throws {
        let runner = MockCommandRunner()
        runner.result = CommandResult(
            output: "/Users/donts/Desktop/partial.txt\n",
            terminationStatus: 15,
            timedOut: true
        )
        let service = FileSearchService(runner: runner)
        let result = try await service.search(query: "partial", timeout: .milliseconds(300))
        #expect(result.paths.map(\.lastPathComponent) == ["partial.txt"])
        #expect(result.timedOut)
    }

    @Test func commandFailureThrows() async {
        let runner = MockCommandRunner()
        runner.result = CommandResult(output: "", terminationStatus: 1, timedOut: false)
        let service = FileSearchService(runner: runner)
        await #expect(throws: (any Error).self) {
            try await service.search(query: "x", timeout: .milliseconds(300))
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make test`
Expected: `FileSearchService` 不存在。

- [ ] **Step 3: 实现命令执行与搜索**

`ProcessCommandRunner` 必须：
- 使用 `Process`、`Pipe`；
- 超时后 `terminate()`，`CommandResult.timedOut = true`；
- 取消时终止进程；
- 只 resume 一次。

实现骨架：

```swift
import Foundation

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let state = CommandState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    state.finish(
                        with: CommandResult(
                            output: output,
                            terminationStatus: finished.terminationStatus,
                            timedOut: state.timedOut
                        ),
                        continuation: continuation
                    )
                }
                do {
                    try process.run()
                } catch {
                    state.finish(with: error, continuation: continuation)
                    return
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    guard process.isRunning else { return }
                    state.markTimedOut()
                    process.terminate()
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

private final class CommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var _timedOut = false

    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return _timedOut
    }

    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        _timedOut = true
    }

    func finish(with result: CommandResult, continuation: CheckedContinuation<CommandResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(returning: result)
    }

    func finish(with error: Error, continuation: CheckedContinuation<CommandResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
```

注意：超时后 `process.terminate()` 触发 `terminationHandler`，读取部分输出。若进程无法终止，需要再等待一个短超时并强制 `interrupt()`，实现时补上。

`FileSearchService` 过滤与排序：

```swift
import Foundation

public struct FileSearchResult: Sendable {
    public let paths: [URL]
    public let timedOut: Bool

    public init(paths: [URL], timedOut: Bool) {
        self.paths = paths
        self.timedOut = timedOut
    }
}

public struct FileSearchService: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func search(query: String, timeout: Duration) async throws -> FileSearchResult {
        let result = try await runner.run(
            executable: "/usr/bin/mdfind",
            arguments: ["-name", query],
            timeout: timeout
        )

        if result.output.isEmpty && result.terminationStatus != 0 && !result.timedOut {
            throw ActionError.commandFailed("文件搜索不可用")
        }

        let excludedPrefixes = ["/System/", "/Library/", "/private/", "/Users/Shared/"]
        var seen: Set<String> = []
        var paths: [(url: URL, score: Double)] = []

        for line in result.output.split(whereSeparator: \.isNewline) {
            let path = String(line)
            guard !path.isEmpty,
                  !excludedPrefixes.contains(where: { path.hasPrefix($0) }),
                  !path.hasSuffix(".app"),
                  !path.contains(".app/") else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.pathComponents.dropFirst().allSatisfy({ !$0.hasPrefix(".") }) else { continue }
            guard seen.insert(url.path).inserted else { continue }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            guard let score = FuzzyMatcher.score(query: query, candidate: url.lastPathComponent) else {
                continue
            }
            paths.append((url, score))
            if paths.count >= 200 { break }
        }

        let top = paths
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            .prefix(12)
            .map(\.url)

        return FileSearchResult(paths: top, timedOut: result.timedOut)
    }
}
```

- [ ] **Step 4: 实现 FileProvider**

```swift
import Foundation

@MainActor
public final class FileProvider: ToolProvider {
    public let id = ProviderID.file.rawValue
    public let displayName = "文件"
    public let keywords: [String] = []
    public let priority = 50
    public let phase = SearchPhase.slow
    public private(set) var statusNotice: String?

    private let settings: SettingsStore
    private let usage: UsageStore
    private let launcher: AppLaunching
    private let feedback: FeedbackProviding
    private let service: FileSearchService

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) && settings.fileSearchEnabled }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        settings: SettingsStore,
        usage: UsageStore,
        launcher: AppLaunching,
        feedback: FeedbackProviding,
        service: FileSearchService = FileSearchService()
    ) {
        self.settings = settings
        self.usage = usage
        self.launcher = launcher
        self.feedback = feedback
        self.service = service
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        statusNotice = nil
        guard case .global = context.mode, isEnabled, !context.query.isEmpty else { return [] }

        do {
            let result = try await service.search(query: context.query, timeout: .milliseconds(300))
            if result.timedOut {
                statusNotice = result.paths.isEmpty ? "文件搜索超时" : "文件搜索较慢，已显示部分结果"
            }
            return result.paths.prefix(12).map(makeItem)
        } catch {
            statusNotice = "文件搜索不可用"
            Log.provider.error("文件搜索失败: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func makeItem(url: URL) -> SearchItem {
        let launcher = self.launcher
        let usage = self.usage
        let feedback = self.feedback
        let key = url.path
        let score = FuzzyMatcher.score(query: url.lastPathComponent, candidate: url.lastPathComponent).map {
            $0 + usage.boost(for: key)
        } ?? usage.boost(for: key)

        return SearchItem(
            providerID: id,
            group: .file,
            title: url.lastPathComponent,
            subtitle: PathDisplay.parentDirectory(of: url),
            icon: .file(path: url.path),
            score: score,
            canonicalKey: key,
            actions: [
                ItemAction(id: "file.open", title: "打开") {
                    do {
                        try launcher.openFile(at: url)
                        usage.recordUse(of: key)
                    } catch {
                        feedback.show(error.localizedDescription)
                    }
                },
                ItemAction(id: "file.reveal", title: "在 Finder 中显示") {
                    launcher.revealInFinder(url)
                }
            ]
        )
    }
}
```

评分应使用查询与文件名的匹配分，而不是文件名与自身（那永远是 1000）。实现时把 `service.search` 返回的原始查询传入，或让 `FileSearchService` 返回 `(URL, score)` 列表，Provider 直接使用。建议修改 `FileSearchResult` 为 `[(url: URL, score: Double)]`，Provider 用该分数加 usage boost。测试可相应断言排序。

- [ ] **Step 5: 运行测试**

Run: `make test`
Expected: `FileSearchServiceTests` 通过。

- [ ] **Step 6: 接入 AppController**

注册 `FileProvider`，注入 `SystemAppLauncher` 和 toast。手动验证：
- 输入常见文件名片段，300ms 内出现文件结果。
- 回车打开；`Cmd+Enter` 在 Finder 中定位。
- 关闭文件搜索后不再出现文件结果。
- `mdfind` 不可用时其他结果正常，底栏显示“文件搜索不可用”。

---

### Task 14: 翻译

**Files:**
- Create: `Sources/DontsToolCore/Core/LanguageIdentification.swift`
- Create: `Sources/DontsToolCore/Services/TranslationService.swift`
- Create: `Sources/DontsToolCore/Providers/TranslationProvider.swift`
- Test: `Tests/DontsToolCoreTests/TranslationProviderTests.swift`

**Interfaces:**
- Consumes: `Translation`、`SwiftUI`、`ClipboardProviding`、`FeedbackProviding`、`ProgressReporting`、`SettingsStore`、`QueryPrefilling`
- Produces:
  - `TranslationServicing` 协议（`canTranslate(_:target:)`、`translate(_:target:)`）
  - `SystemTranslationService`
  - `LanguageIdentifying` 协议与 `NaturalLanguageIdentifier`
  - `TranslationProvider`（keyword `tr`，fast）

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
@testable import DontsToolCore

@MainActor
final class MockTranslator: TranslationServicing {
    var canTranslate = true
    var translated: [String] = []
    var error: Error?
    func canTranslate(_ text: String, target: String) async -> Bool { canTranslate }
    func translate(_ text: String, target: String) async throws -> String {
        if let error { throw error }
        translated.append(text)
        return "译文"
    }
}

struct FixedLanguageIdentifier: LanguageIdentifying {
    let language: String?
    func dominantLanguageCode(of text: String) -> String? { language }
}

@MainActor
final class MockProgress: ProgressReporting {
    var events: [String] = []
    func begin(_ message: String) { events.append("begin:\(message)") }
    func end() { events.append("end") }
}

@Suite("TranslationProvider")
@MainActor
struct TranslationProviderTests {
    private func makeProvider(
        canTranslate: Bool = true,
        sourceLanguage: String? = "en",
        target: String = "zh-Hans"
    ) -> (TranslationProvider, MockTranslator, MockClipboard, MockFeedback, MockPrefiller) {
        let suite = "dontstool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults, systemLanguageCode: "en")
        settings.setTranslationTarget(target)
        let translator = MockTranslator()
        translator.canTranslate = canTranslate
        let clipboard = MockClipboard()
        let feedback = MockFeedback()
        let prefill = MockPrefiller()
        let provider = TranslationProvider(
            settings: settings,
            translator: translator,
            clipboard: clipboard,
            feedback: feedback,
            progress: MockProgress(),
            prefill: prefill,
            languageIdentifier: FixedLanguageIdentifier(language: sourceLanguage)
        )
        return (provider, translator, clipboard, feedback, prefill)
    }

    @Test func supportedPairShowsSystemAndWebItems() async {
        let (provider, _, _, _, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "tr hello",
            mode: .keyword(providerID: "translation", keyword: "tr", argument: "hello")
        )
        let items = await provider.search(context)
        #expect(items.count == 2)
        #expect(items[0].group == .tool)
        #expect(items[1].group == .web)
    }

    @Test func unsupportedPairShowsOnlyWebFallback() async {
        let (provider, _, _, _, _) = makeProvider(canTranslate: false)
        let context = SearchContext(
            rawQuery: "tr hello",
            mode: .keyword(providerID: "translation", keyword: "tr", argument: "hello")
        )
        let items = await provider.search(context)
        #expect(items.count == 1)
        #expect(items[0].group == .web)
    }

    @Test func sameLanguageIsNotTranslated() async {
        let (provider, translator, _, _, _) = makeProvider(sourceLanguage: "zh")
        let context = SearchContext(
            rawQuery: "tr 你好",
            mode: .keyword(providerID: "translation", keyword: "tr", argument: "你好")
        )
        let items = await provider.search(context)
        #expect(translator.translated.isEmpty)
        #expect(items.contains { $0.subtitle?.contains("相同") == true })
    }

    @Test func translationCopiesResultAndReportsProgress() async throws {
        let (provider, translator, clipboard, feedback, _) = makeProvider()
        let context = SearchContext(
            rawQuery: "tr hello",
            mode: .keyword(providerID: "translation", keyword: "tr", argument: "hello")
        )
        let items = await provider.search(context)
        try await items[0].primaryAction?.run()
        #expect(translator.translated == ["hello"])
        #expect(clipboard.written == ["译文"])
        #expect(feedback.messages.contains { $0.contains("译文") })
    }

    @Test func emptyQueryReturnsPrefillHint() async throws {
        let (provider, _, _, _, prefill) = makeProvider()
        let items = await provider.search(SearchContext(rawQuery: "", mode: .global))
        #expect(items.count == 1)
        try await items[0].primaryAction?.run()
        #expect(prefill.queries == ["tr "])
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make test`
Expected: `TranslationProvider` / `TranslationServicing` 不存在。

- [ ] **Step 3: 实现语言识别与翻译服务**

`Sources/DontsToolCore/Core/LanguageIdentification.swift`：

```swift
import Foundation
import NaturalLanguage

public protocol LanguageIdentifying: Sendable {
    func dominantLanguageCode(of text: String) -> String?
}

public struct NaturalLanguageIdentifier: LanguageIdentifying {
    public init() {}

    public func dominantLanguageCode(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
```

`Sources/DontsToolCore/Services/TranslationService.swift`：

```swift
import Foundation
import SwiftUI
import Translation

@MainActor
public protocol TranslationServicing: AnyObject {
    func canTranslate(_ text: String, target: String) async -> Bool
    func translate(_ text: String, target: String) async throws -> String
}

@MainActor
public final class SystemTranslationService: TranslationServicing {
    private let model = TranslationHostModel()
    private var hostWindow: NSWindow?

    public init() {}

    public func canTranslate(_ text: String, target: String) async -> Bool {
        let availability = LanguageAvailability()
        let status = await availability.status(
            for: text,
            to: Locale.Language(identifier: target)
        )
        switch status {
        case .installed, .supported:
            return true
        case .unsupported:
            return false
        @unknown default:
            return false
        }
    }

    public func translate(_ text: String, target: String) async throws -> String {
        ensureHostWindow()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [model] in
                try await model.translate(text, target: target)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw ActionError.translationFailed("翻译超时")
            }
            guard let first = try await group.next() else {
                throw ActionError.translationFailed("翻译失败")
            }
            group.cancelAll()
            return first
        }
    }

    private func ensureHostWindow() {
        if hostWindow != nil { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.contentView = NSHostingView(rootView: TranslationHostView(model: model))
        window.orderFrontRegardless()
        hostWindow = window
    }
}

@MainActor
final class TranslationHostModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    private var pending: PendingTranslation?

    struct PendingTranslation {
        let text: String
        let target: String
        let continuation: CheckedContinuation<String, Error>
    }

    func translate(_ text: String, target: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pending = PendingTranslation(text: text, target: target, continuation: continuation)
            var configuration = TranslationSession.Configuration(
                source: nil,
                target: Locale.Language(identifier: target)
            )
            configuration.invalidate()
            self.configuration = configuration
        }
    }

    func run(session: TranslationSession) async {
        guard let pending else { return }
        self.pending = nil
        do {
            let response = try await session.translate(pending.text)
            pending.continuation.resume(returning: response.targetText)
        } catch {
            pending.continuation.resume(throwing: error)
        }
    }
}

struct TranslationHostView: View {
    @ObservedObject var model: TranslationHostModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.configuration) { session in
                await model.run(session: session)
            }
    }
}
```

实现时验证：
- `import Translation` 与 `import SwiftUI` 能解析 `.translationTask`（交叉导入 overlay）。
- 同一语言对连续翻译是否会重新触发；若不会，在每次请求前对 `configuration` 调用 `invalidate()` 并赋新值。
- 透明 2×2 宿主窗口是否能让 `translationTask` 运行；若不行，改为 1×1 可见但完全透明的窗口，并记录原因。

- [ ] **Step 4: 实现 TranslationProvider**

```swift
import Foundation

@MainActor
public final class TranslationProvider: ToolProvider {
    public let id = ProviderID.translation.rawValue
    public let displayName = "翻译"
    public let keywords = ["tr"]
    public let priority = 150
    public let phase = SearchPhase.fast
    public var statusNotice: String? { nil }

    private let settings: SettingsStore
    private let translator: TranslationServicing
    private let clipboard: ClipboardProviding
    private let feedback: FeedbackProviding
    private let progress: ProgressReporting
    private let prefill: QueryPrefilling
    private let languageIdentifier: LanguageIdentifying

    public var isEnabled: Bool {
        get { settings.isProviderEnabled(id) }
        set { settings.setProviderEnabled(id, to: newValue) }
    }

    public init(
        settings: SettingsStore,
        translator: TranslationServicing,
        clipboard: ClipboardProviding,
        feedback: FeedbackProviding,
        progress: ProgressReporting,
        prefill: QueryPrefilling,
        languageIdentifier: LanguageIdentifying = NaturalLanguageIdentifier()
    ) {
        self.settings = settings
        self.translator = translator
        self.clipboard = clipboard
        self.feedback = feedback
        self.progress = progress
        self.prefill = prefill
        self.languageIdentifier = languageIdentifier
    }

    public func search(_ context: SearchContext) async -> [SearchItem] {
        guard isEnabled else { return [] }

        switch context.mode {
        case .keyword(let providerID, _, _) where providerID == id:
            return await translationItems(argument: context.query)
        case .global where context.query.isEmpty:
            return [hintItem()]
        default:
            return []
        }
    }

    private func translationItems(argument: String) async -> [SearchItem] {
        let target = settings.translationTarget
        let targetLanguageCode = Locale.Language(identifier: target).languageCode?.identifier
        var items: [SearchItem] = []

        let sourceLanguage = argument.isEmpty ? nil : languageIdentifier.dominantLanguageCode(of: argument)
        let sameLanguage = sourceLanguage != nil
            && sourceLanguage?.hasPrefix(targetLanguageCode ?? "") == true

        if sameLanguage {
            items.append(sameLanguageItem(argument: argument, target: target))
        } else if argument.isEmpty || await translator.canTranslate(argument, target: target) {
            items.append(systemItem(argument: argument, target: target))
        }

        items.append(webFallbackItem(argument: argument, target: target))
        return items
    }

    private func systemItem(argument: String, target: String) -> SearchItem {
        let translator = self.translator
        let clipboard = self.clipboard
        let feedback = self.feedback
        let progress = self.progress
        let targetName = Locale.current.localizedString(forIdentifier: target) ?? target
        let summary = argument.isEmpty ? "剪贴板内容" : summarize(argument)

        return SearchItem(
            providerID: id,
            group: .tool,
            title: "翻译：\(summary)",
            subtitle: "译为\(targetName) · 回车复制译文",
            icon: .symbol(name: "character.bubble"),
            score: 1000,
            canonicalKey: "tr:\(target):\(argument)",
            actions: [
                ItemAction(
                    id: "translation.system",
                    title: "翻译并复制",
                    presentation: .keepPanelUntilComplete
                ) {
                    let text: String
                    if argument.isEmpty {
                        guard let clipboardText = clipboard.readString(), !clipboardText.isEmpty else {
                            throw ActionError.clipboardEmpty
                        }
                        text = clipboardText
                    } else {
                        text = argument
                    }

                    progress.begin("正在翻译…")
                    defer { progress.end() }
                    do {
                        let translated = try await translator.translate(text, target: target)
                        clipboard.writeString(translated)
                        feedback.show("已复制译文：\(summarize(translated))")
                    } catch {
                        throw ActionError.translationFailed(error.localizedDescription)
                    }
                }
            ]
        )
    }

    private func sameLanguageItem(argument: String, target: String) -> SearchItem {
        let feedback = self.feedback
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "源语言与目标语言相同",
            subtitle: "无需翻译",
            icon: .symbol(name: "character.bubble"),
            score: 1000,
            canonicalKey: "tr:same:\(argument)",
            actions: [
                ItemAction(id: "translation.same", title: "提示") {
                    feedback.show("源语言与目标语言相同，无需翻译")
                }
            ]
        )
    }

    private func webFallbackItem(argument: String, target: String) -> SearchItem {
        let openerURL = googleTranslateURL(text: argument, target: target)
        let opener = self.opener
        let feedback = self.feedback
        return SearchItem(
            providerID: id,
            group: .web,
            title: "在网页中翻译",
            subtitle: "Google 翻译 · 自动检测源语言",
            icon: .symbol(name: "safari"),
            score: 50,
            canonicalKey: "translate:web:\(target):\(argument)",
            actions: [
                ItemAction(id: "translation.web", title: "在浏览器中打开") {
                    do {
                        try opener.open(openerURL)
                    } catch {
                        feedback.show(error.localizedDescription)
                    }
                }
            ]
        )
    }

    private func hintItem() -> SearchItem {
        let prefill = self.prefill
        return SearchItem(
            providerID: id,
            group: .tool,
            title: "翻译",
            subtitle: "输入 tr + 文本；空参数读取剪贴板",
            icon: .symbol(name: "character.bubble"),
            score: 800,
            canonicalKey: "hint:translation",
            actions: [
                ItemAction(id: "translation.prefill", title: "填入关键词") {
                    prefill.prefill("tr ")
                }
            ]
        )
    }

    private func googleTranslateURL(text: String, target: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "translate.google.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: webLanguageCode(for: target)),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "op", value: "translate")
        ]
        return components.url!
    }

    private func webLanguageCode(for target: String) -> String {
        if target.hasPrefix("zh") { return "zh-CN" }
        return target
    }

    private func summarize(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 80 { return singleLine }
        return String(singleLine.prefix(80)) + "…"
    }
}
```

注意：`TranslationProvider` 还缺少 `opener` 属性；实现时注入 `URLOpening`，并在测试中提供 `MockURLOpener`。搜索阶段不打开浏览器。

- [ ] **Step 5: 运行测试**

Run: `make test`
Expected: `TranslationProviderTests` 通过（系统翻译服务用一个 mock 替代）。

- [ ] **Step 6: 手动验证真实翻译**

接入 `SystemTranslationService` 与 `SystemURLOpener`，运行 `make run ARGS=--show-panel`：
- `tr hello` 在支持的语言对下返回译文并复制。
- 不支持的语言对只显示网页翻译。
- 相同语言显示提示。
- 翻译中底栏显示“正在翻译…”，失败时 Toast 且面板保持打开。
- 首次下载语言资源时界面不崩溃。

---

### Task 15: 设置页、热键录制与开机启动

**Files:**
- Create: `Sources/DontsTool/Settings/SettingsWindowController.swift`
- Create: `Sources/DontsTool/Settings/SettingsView.swift`
- Create: `Sources/DontsTool/Settings/HotKeyRecorderView.swift`
- Create: `Sources/DontsToolCore/Services/LoginItemManager.swift`
- Modify: `Sources/DontsTool/App/AppController.swift`
- Modify: `Sources/DontsTool/App/MenuBarController.swift`
- Modify: `Sources/DontsTool/Shell/LauncherPanelController.swift`

**Interfaces:**
- Consumes: `SettingsStore`、`AppIndex`、`HotKeyManager`、`SMAppService`
- Produces: 完整设置窗口、热键录制、登录项开关。

- [ ] **Step 1: 实现登录项管理**

```swift
import Foundation
import ServiceManagement

@MainActor
public final class LoginItemManager: ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var message: String?

    public init() {
        refresh()
    }

    public func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
        switch SMAppService.mainApp.status {
        case .requiresApproval:
            message = "请在“系统设置 → 通用 → 登录项”中允许 DontsTool"
        case .notFound:
            message = "系统未找到登录项"
        default:
            message = nil
        }
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "登录项设置失败，请前往系统设置检查"
        }
        refresh()
    }
}
```

- [ ] **Step 2: 热键录制控件**

`HotKeyRecorderView` 使用 `NSViewRepresentable` 包装 `HotKeyRecorderButton`，按钮显示当前快捷键；点击后 `window?.makeFirstResponder(self)`；`keyDown`：

```swift
override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
        stopRecording()
        return
    }
    let modifiers = carbonModifiers(from: event.modifierFlags)
    guard modifiers != 0 else {
        NSSound.beep()
        return
    }
    let configuration = SettingsStore.HotKeyConfiguration(
        keyCode: UInt32(event.keyCode),
        modifiers: modifiers
    )
    if let error = onApply(configuration) {
        errorMessage = error
        NSSound.beep()
        return
    }
    stopRecording()
}

private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var value: UInt32 = 0
    if flags.contains(.control) { value |= 4096 }
    if flags.contains(.option) { value |= 2048 }
    if flags.contains(.shift) { value |= 512 }
    if flags.contains(.command) { value |= 256 }
    return value
}
```

- [ ] **Step 3: 设置界面**

`SettingsView` 使用 `Form`，分区与绑定：
- 通用：`HotKeyRecorderView`（显示 `HotKeyFormatter.displayString`），错误文案；Toggle 开机启动绑定 `LoginItemManager`。
- 搜索：Picker 默认搜索引擎；Toggle 启用文件搜索。
- 工具：Toggle 应用、文本工具、网页搜索、翻译；文件搜索由搜索分区控制。
- 翻译：Picker 目标语言（`zh-Hans`、`en`、`ja`、`ko`、`fr`、`de`、`es`）。
- 索引：`已索引 \(appIndex.apps.count) 个应用`，重新扫描按钮。
- 关于：`DontsTool \(AppInfo.version)`，重新查看使用说明按钮。

`SettingsWindowController`：

```swift
@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(settings: SettingsStore, appIndex: AppIndex, loginItem: LoginItemManager, ...) {
        let view = SettingsView(...)
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "DontsTool 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 560))
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 4: 热键应用失败回滚**

AppController 提供：

```swift
func applyHotKey(_ configuration: SettingsStore.HotKeyConfiguration) -> String? {
    let previous = settings.hotKey
    do {
        try hotKeyManager.register(configuration)
        settings.setHotKey(configuration)
        menuBar?.hotKeyDisplay = HotKeyFormatter.displayString(for: configuration)
        return nil
    } catch {
        try? hotKeyManager.register(previous)
        return error.localizedDescription
    }
}
```

设置页调用该方法；失败时显示内联错误，不改设置。

- [ ] **Step 5: 接线菜单与 Cmd+,**

菜单栏增加“打开设置…”（`Cmd+,`）；面板 `onOpenSettings` 关闭面板后打开设置。`SearchField` 已拦截 `Cmd+,`。

- [ ] **Step 6: 构建与手动验收**

Run: `make test && make run ARGS=--show-panel`
- 修改热键后立即生效，重启后保留。
- 录制无修饰键组合被拒绝；Esc 取消。
- 热键冲突时设置页显示错误并保留旧热键。
- 启动项开关状态以系统为准；需要审批时显示提示。
- 关闭某 Provider 后搜索不再返回该组结果。

---

### Task 16: 首次运行引导与错误状态收尾

**Files:**
- Create: `Sources/DontsTool/Settings/OnboardingWindowController.swift`
- Modify: `Sources/DontsTool/App/AppController.swift`
- Modify: `Sources/DontsTool/App/MenuBarController.swift`
- Modify: `Sources/DontsTool/Shell/LauncherPanelController.swift`

**Interfaces:**
- Consumes: `SettingsStore.hasCompletedOnboarding`
- Produces: 首次启动引导、菜单项“使用说明”、完整状态展示。

- [ ] **Step 1: 引导窗口**

内容：
- 默认热键 `⌥Space`（根据当前设置显示）。
- 菜单栏图标说明。
- 文件搜索首次可能请求 Spotlight/完全磁盘访问权限。
- 按钮“打开设置”和“开始使用”。

关闭或点击开始时 `settings.completeOnboarding()`。AppController 在完成热键注册与索引启动后，如果 `!settings.hasCompletedOnboarding`，延迟 0.6s 显示引导。菜单栏“使用说明”可重新打开（不重置 onboarding 状态）。

- [ ] **Step 2: 错误状态**

确认：
- 热键注册失败：记录日志；菜单栏仍可打开面板；设置页可看到尝试注册的错误（通过状态字段或 toast）。
- 索引失败：保留旧快照；设置页显示 `lastError`。
- 文件搜索不可用/超时：底部状态文案，其他结果不丢。
- 翻译失败：Toast 且面板保持。
- 剪贴板为空：Toast。
- 打开应用/文件/URL 失败：Toast。

- [ ] **Step 3: 手动验收**

逐项执行 Spec 9.3 的清单，记录通过/失败。失败项开新任务修复，不在此任务里静默跳过。

---

## M4：打磨与验收

### Task 17: 性能测量与优化

**Files:**
- Create: `Sources/DontsTool/App/Performance.swift`
- Modify: `Sources/DontsTool/Shell/LauncherPanelController.swift`
- Modify: `Sources/DontsTool/Shell/ResultListViewController.swift`
- Modify: `Sources/DontsTool/Shell/IconLoader.swift`
- Test: `Tests/DontsToolCoreTests/PerformanceTests.swift`

**Interfaces:**
- Consumes: 全部
- Produces: signpost 埋点与性能验收数据。

- [ ] **Step 1: 加 signpost**

`Performance.swift`：

```swift
import os

enum Performance {
    static let signposter = OSSignposter(subsystem: "com.donts.DontsTool", category: "performance")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
```

在 `LauncherPanelController.show()` 开始 `panel.show` 区间，在 `makeKeyAndOrderFront` 后结束；在 `refreshSearch` 开始 `search.fast`，在收到首帧结果后结束。文件搜索区间放在 `FileProvider.search`。

- [ ] **Step 2: 合成基准测试**

用 5000 个应用名，连续 1000 次 `FuzzyMatcher.score` + 排序，测量 p50/p95；测试只打印结果，不做硬性失败阈值（机器差异大），把数据记录到 PR/验收记录。

- [ ] **Step 3: 优化检查**

- 应用扫描在后台，启动不阻塞热键。
- 图标按路径缓存，滚动不重复读磁盘。
- `NSTableView` 复用行视图，不重建。
- 快速 Provider 不做磁盘 I/O；文件 Provider 只使用 slow 阶段。
- 使用统计 2 秒防抖写盘。
- 空查询不触发慢速搜索。
- 用 Activity Monitor 观察空闲 CPU、内存。

- [ ] **Step 4: 记录数据**

在实现记录中写下：热键→可见、快速结果、文件结果、冷启动、内存、空闲 CPU 的实测值，与预算对比。未达标项列出原因和后续任务。

---

### Task 18: 无障碍、悬停与视觉打磨

**Files:**
- Modify: `Sources/DontsTool/Shell/ResultListViewController.swift`
- Modify: `Sources/DontsTool/Shell/SearchField.swift`
- Modify: `Sources/DontsTool/Shell/LauncherPanelController.swift`
- Modify: `Sources/DontsTool/App/MenuBarController.swift`

- [ ] **Step 1: 无障碍**

- 搜索框 `setAccessibilityLabel("搜索")`，并设置帮助文本。
- 结果列表 `setAccessibilityLabel("搜索结果")`，每行设置组合标签（标题 + 副标题 + 主操作）。
- 菜单栏按钮设置 `setAccessibilityLabel("DontsTool")`。
- Toast 文本可被 VoiceOver 读取：设置 `setAccessibilityElement(true)` 和 label。
- 确认仅键盘可完成所有操作。

- [ ] **Step 2: 悬停高亮与滚动**

- 在 `ResultRowView` 加 `NSTrackingArea`，鼠标进入时显示浅色背景，离开时清除；不要影响选中态。
- 键盘移动选中项时 `scrollRowToVisible`。
- 列表内容超出时垂直滚动，底部状态栏固定。

- [ ] **Step 3: 明暗模式与多屏**

- 用 `.popover` material，确认明暗模式切换正常。
- 面板在鼠标所在屏幕定位；全屏 Space 可呼出。
- 面板消失后焦点恢复。

---

### Task 19: 发布构建、文档同步与最终验收

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/superpowers/specs/2026-10-18-dontstool-design.md`（如有实现差异）
- Modify: `Makefile`（如需）
- Test: 全部

- [ ] **Step 1: 运行完整验证**

Run:

```bash
make test
make app
make release
```

Expected: 测试全部通过；Debug/Release App 均构建成功；ad-hoc 签名有效；`build/DontsTool-0.1.0.zip` 可解压启动。

- [ ] **Step 2: 手动验收**

按 Spec 9.3 清单逐项执行并记录：
- 热键呼出/隐藏、切换、失焦、Esc。
- 焦点恢复；中文输入法拼音、候选、上屏。
- 多显示器、全屏 Space、明暗模式。
- 应用/文件搜索与打开、Finder 定位。
- 每个文本工具正常与错误输入。
- 网页关键词与兜底。
- 翻译成功、不支持语言对、首次下载、失败。
- 设置持久化，重启后热键与开关生效。
- 登录项。
- 无 Spotlight / 无完全磁盘访问降级。
- 长时间驻留资源稳定。

- [ ] **Step 3: 文档同步**

- README 当前状态改为 V1 可用，并补充实际构建/运行命令。
- Architecture 与 Spec 的协议、目录、行为与实现一致。
- 记录性能实测数据与已知限制。
- 如新增架构决策（例如翻译宿主窗口方案），写新 ADR，不修改历史 ADR。

- [ ] **Step 4: 最终检查**

- 没有调试输出、占位代码、未使用的 `cancelScan` 等无效方法。
- 没有第三方运行时依赖。
- 没有用户数据上报或后台网络请求。
- 所有错误路径有可读中文提示。
- `git status` 检查（如果届时已初始化仓库）只包含预期文件；**未经用户明确要求，不提交。**

---

## 自检记录

- Spec 覆盖：启动器面板、应用/文件、文本工具、网页搜索、翻译、设置、首次运行、错误降级、性能、测试计划均有对应任务。
- 刻意推迟：运行时插件、剪贴板历史、预览面板、拼音匹配，均在 Spec 非目标或后续工作。
- 类型一致性：`SearchItem.canonicalKey` 用于去重；`ItemAction.presentation` 用于翻译保持面板；`ToolProvider.phase` 用于两阶段搜索；`statusNotice` 用于文件降级。
- 提交：按用户约束，计划不含 commit 步骤。

## 验收记录（2026-10-18）

**自动验证通过**

- 96 个单元测试（Core 逻辑、Provider、搜索协调、翻译服务请求/解析/错误、性能基准）。
- Debug 与 Release 构建成功；Release ad-hoc 签名有效；`build/DontsTool-0.1.0.zip` 生成。
- 启动冒烟：Release 二进制带 `--show-panel --show-settings` 运行无崩溃、无错误日志。
- 性能：冷启动 53.5ms；面板可见 1.5–28.5ms；快速结果 1.4–50ms；空闲 CPU 0.0%；内存 ≈112MB。
- 代码卫生：无 print/NSLog/TODO/占位/未使用方法；无第三方运行时依赖；联网仅发生在用户主动执行网页搜索或翻译时。

**需真机手动验收（用户执行）**

- 热键呼出/隐藏、Esc、失焦隐藏、焦点恢复；中文输入法组合与候选。
- 多显示器、全屏 Space、明暗模式切换。
- 应用/文件打开与 Finder 定位；各文本工具正常与错误输入；网页关键词与兜底。
- 配置翻译 API 后 `tr` 翻译成功与失败提示；未配置时配置提示项。
- 设置持久化（重启后热键/开关生效）、登录项开关、首次运行引导与「使用说明」。
- 视觉对照 `design/` 设计稿的偏差反馈。

### 修复记录：热键呼出后空白（2026-10-18）

真机回归发现按 `⌥Space` 呼出后面板只剩零星胶囊、列表空白。三个叠加根因：

1. 呼出动效直接设置 `contentView.layer.anchorPoint` 并加 transform 动画，导致 SwiftUI 图层永久位移/裁剪。改为只做窗口 `alphaValue` 动画（[LauncherPanelController.swift](../../../Sources/DontsTool/Shell/LauncherPanelController.swift)）。
2. `Theme.hexColor` 用 `value > 0xFFFFFF` 判断是否带 alpha，`0x00000008` 这类前导零色值被当成不透明近黑色，键帽/分隔线/边框全部变黑。改为显式 `rgba(rgb, alpha)`，令牌与图标着色全部重写（[Theme.swift](../../../Sources/DontsTool/UI/DesignSystem/Theme.swift)）。
3. 鼠标悬停会调用 `model.select` 改变选中项，列表跟着滚动到鼠标所在行。悬停改为仅影响背景高亮，不再改变键盘选中项（[ResultRowView.swift](../../../Sources/DontsTool/UI/Components/ResultRowView.swift)）。

修复后用系统截图核对了浅色、深色面板与设置窗口；96 个测试通过。

### 修复记录：任意查询都显示计算器（2026-10-18）

搜索逻辑本身没有把「测试」匹配到 Calculator，问题出在 SwiftUI 列表复用：`LazyVStack` 配 `ForEach` 下标身份时，查询变化后行视图被错误复用，旧的计算器行残留在首行。修复：

1. 面板列表由 `LazyVStack` 改为 `VStack`，行身份改用稳定的 `item.id`，分组标题也使用独立 id（[LauncherPanelView.swift](../../../Sources/DontsTool/UI/Launcher/LauncherPanelView.swift)）。
2. 选中项变化时按 `selectedItem?.id` 滚动；结果集变化时滚回第一个分组标题，保证「常用」可见。
3. 补上随查询内容出现的清除按钮，并将空查询常用应用上限收敛为 4 个，避免列表过密。
4. 移除热键调试日志与临时 `--query` 参数，保留 README 中记录的 `--show-panel` / `--show-settings`。

用查询「测试」与空查询截图复核：前者只显示 Google 网页兜底行，后者正确呈现「常用」应用与「工具」关键词；96 个测试通过。

### 修复记录：自定义呼出快捷键不生效（2026-10-18）

设置页早有录制入口，但录制器把 `NSEvent.ModifierFlags.rawValue` 直接写入 Carbon 热键位（`⌥` 的 Cocoa 位是 524288，Carbon 位是 2048），保存后注册失败。修复：

1. `HotKeyConfiguration` 增加 Carbon `Modifier` 常量与 `carbonModifiers(command:shift:option:control:)` 转换；录制器只接受含 `⌘/⌥/⌃` 的组合，Esc 取消（[HotKeyRecorder.swift](../../../Sources/DontsTool/UI/Settings/HotKeyRecorder.swift)）。
2. 录制期间临时注销旧热键，避免想改回旧组合时被 Carbon 拦截直接呼出面板（[HotKeyManager.swift](../../../Sources/DontsTool/Shell/HotKeyManager.swift)）。
3. 面板右上角与设置侧栏改为显示实际快捷键，不再写死 `⌥ Space`；`HotKeyFormatter` 为 `Space` 这类单词键补空格（[LauncherPanelView.swift](../../../Sources/DontsTool/UI/Launcher/LauncherPanelView.swift)）。
4. 新组合注册失败时重新注册并恢复旧配置，避免旧热键被吞掉（[AppController.swift](../../../Sources/DontsTool/App/AppController.swift)）。

真机验证：点击录制后按下 `⌃⌥J`，UserDefaults 保存为 keyCode 38 / modifiers 6144，面板与设置侧栏同步显示 `⌃⌥J`，再次按下可呼出面板；随后恢复 `⌥ Space`。98 个测试通过。

### 菜单栏图标与菜单收口（2026-10-18）

按使用反馈把常驻入口收敛为一个 D 形状态栏图标，菜单只保留“打开启动器”和“退出 DontsTool”（[MenuBarController.swift](../../../Sources/DontsTool/App/MenuBarController.swift)）：

1. 图标从放大镜改为 `d.square`，避免与 Spotlight 混淆；设置 `autosaveName`，用户用 ⌘ 拖动图标后位置可被系统记住。
2. 移除菜单里的重新扫描、设置、使用说明项；设置仍可从面板齿轮或 `Cmd + ,` 进入，使用说明保留在设置“通用”页。
3. 菜单动作经真机点击验证：打开启动器可正常显示面板，退出可正常结束进程。

注意：本机菜单栏使用 Hidden Bar 收纳图标，新状态项默认位于折叠区（窗口被移到屏幕外）；展开右侧箭头可见，或用 ⌘ 将 D 图标拖到分隔线右侧即可常驻。

### 双击修饰键快捷键（2026-10-18）

新增第二种热键形态 `HotKeyConfiguration.Kind.doubleTap`，支持双击 `⌘/⌥/⌃/⇧`：

1. **模型与持久化**：`dontstool.hotkey.kind` 保存 `combination` / `doubleTap`；双击模式下 keyCode 为 0、modifiers 为被双击的修饰键位。`HotKeyFormatter` 显示 `⌥⌥`（[SettingsStore.swift](../../../Sources/DontsToolCore/Core/SettingsStore.swift)、[HotKeyFormatter.swift](../../../Sources/DontsToolCore/Core/HotKeyFormatter.swift)）。
2. **检测器**：`ModifierDoubleTapDetector` 是纯状态机，两次短按间隔 ≤ 300ms、期间无普通按键或额外修饰键、触发后 500ms 冷却；单测覆盖超时、长按、按键打断、其他修饰键打断和冷却（[ModifierDoubleTapDetector.swift](../../../Sources/DontsToolCore/Core/ModifierDoubleTapDetector.swift)）。
3. **全局监听**：`ModifierDoubleTapMonitor` 使用 `.cgSessionEventTap` + `.listenOnly` 监听 `flagsChanged`/`keyDown`，只读修饰键状态，不拦截、不记录按键内容；tap 被系统禁用时自动重新启用（[ModifierDoubleTapMonitor.swift](../../../Sources/DontsTool/Shell/ModifierDoubleTapMonitor.swift)）。
4. **权限**：首次录制双击时调用 `CGRequestListenEventAccess()`；设置页显示「输入监控权限」状态和系统设置入口；授权后返回应用或重启生效（[InputMonitoring.swift](../../../Sources/DontsTool/Shell/InputMonitoring.swift)）。
5. **录制**：组合键与双击在同一个本地监听中识别；录制期间暂停 Carbon 与事件监听，避免旧快捷键吞键（[HotKeyRecorder.swift](../../../Sources/DontsTool/UI/Settings/HotKeyRecorder.swift)）。
6. **启停与回退**：AppController 按 kind 在 Carbon/事件监听间切换；双击未授权时临时恢复组合键（默认 `⌥Space`），避免用户被锁在应用外；授权状态变化时自动重试（[AppController.swift](../../../Sources/DontsTool/App/AppController.swift)）。同时修正 `@Published` willSet 时机导致的注册失败回退判断。

验证：108 个测试通过；用合成 `flagsChanged` 事件在设置页录制出 `kind=doubleTap / modifiers=2048 / keyCode=0`，系统弹出「DontsTool 想接收来自任何应用程序的按键」授权提示；未授权时回退的 `⌥Space` 可正常呼出面板。双击运行路径需用户勾选「输入监控」并重启后做最终真机确认；ad-hoc 签名重建后可能需要重新授权。


### 修复记录：双击修饰键移除输入监控前置（2026-10-18）

- 用全局与本地 `NSEvent.flagsChanged` 替代只读 `CGEventTap`，不再订阅全局普通按键。
- 用系统按键计数与最近按键时间打断普通输入；第二次短按松开时触发，排队回调中的不确定序列会保守取消。
- 删除 `InputMonitoring` 检查、请求和设置入口，保留监听创建失败时的组合键回退。
- 先验证原状态机在第二次按下、其他修饰键间隔和排队回调方面的失败，再修复并通过 116 项测试、19 个套件。
- 独立 App 在辅助功能与输入监控均未授权时，收到用户切换到其他应用后实际按下/松开 Option 的全局事件；没有修改系统权限。
- 新决策见 ADR 0005，ADR 0004 保留为历史方案。
- 最终验证：116 项测试通过；Debug 与 Release 构建成功，Debug ad-hoc 签名校验通过；重启本地 Debug App 后设置页显示 `⌥⌥`，已无输入监控权限入口。
