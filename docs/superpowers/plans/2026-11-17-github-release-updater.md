# GitHub Releases Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 无需登录的 GitHub Releases 下载、签名验证、应用内安装与重启。

**Architecture:** Sparkle 负责更新协议及安装；Core 提供稳定版本过滤和异步文档保存门控。现有发布脚本扩展为签名 appcast 的生成和下载回验。

**Tech Stack:** Swift 6、AppKit/SwiftUI、Sparkle 2.10.1、XcodeGen、Python 3、GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-11-17-github-release-updater-design.md`

## Global Constraints

- macOS 26.0+，Universal arm64 / x86_64；保留 ad-hoc 签名。
- 更新包 Ed25519 签名，解压前校验，私钥不入库或输出到日志。
- 无 GitHub 登录或客户端 token；公开发布源启用前保持仓库 private。
- 每日自动检查，用户确认下载与安装；不发送系统配置统计。
- 同版重建不更新，旧短版本不降级，非稳定版本不更新。
- 退出或保存被取消时不得强制重启；旧版需手动安装一次。

## Review Focus

- 本地构建号低于 CI：短版本相同或更低仍不能安装。
- 正在保存与重复点击：只执行一次保存和安装回调。
- 本地便笺或知识库拒绝关闭：安装推迟，用户可再次手动继续。
- 归档被改动或私钥不匹配：签名或发布校验必须失败。
- Release 仍为私有：不得声称无需登录的线上更新已经可用。

### Task 1: 版本与安装门控

**Files:** Create `Sources/DontsToolCore/Updates/UpdateVersion.swift`, `Sources/DontsToolCore/Updates/UpdateInstallationGate.swift`, `Tests/DontsToolCoreTests/UpdateTests.swift`.

**Interfaces:** Produces `UpdateVersion.isNewer(_:than:) -> Bool`; `@MainActor UpdateInstallationGate(prepare: @escaping @MainActor () async -> Bool)`, `postpone(_ install: @escaping @MainActor () -> Void)`, `resume() async`, observable `hasPendingInstallation` and `isPreparing`.

- [x] Write tests: 0.2.7 > 0.2.6; 0.10.0 > 0.9.9; equal/older/invalid/prerelease false. Denied preparation keeps pending without invocation; retry invokes once; concurrent resume calls prepare/install once.
- [x] Run `make test`, confirm missing types fail compilation.
- [x] Implement strict three-component stable comparison and serialized async installation gate.
- [x] Run `make test`, expected all Core tests pass.
- [x] Commit `feat: guard update versions and document-safe installation`.

### Task 2: Sparkle 接入与原生入口

**Files:** Create `Sources/DontsTool/Shell/Updates/AppUpdateController.swift`; modify `project.yml`, `Resources/Info.plist`, `AppController.swift`, `AppDelegate.swift`, `ApplicationMenu.swift`, `MenuBarController.swift`, `SettingsWindowController.swift`, `SettingsRootView.swift`.

**Interfaces:** Consumes Task 1. Produces `AppUpdateController(prepareToInstall:)`, observable `canCheckForUpdates`, `automaticallyChecksForUpdates`, `checkForUpdates()`.

- [x] Add bridge tests exercising real menu actions, pending install retry, and version rejection through the controller boundaries; run focused tests and confirm failures.
- [x] Pin Sparkle 2.10.1; add controller/delegate and menu/settings injection. Preserve existing app termination checks and use install postponement callback to finish saving before Sparkle continues.
- [x] Add public update key/feed/daily checks to plist; suppress automatic downloads and system profiling. Generate update private key outside Git and store CI secret without logging it.
- [x] Run Core and bridge suites; expected all pass. Build app and verify embedded Sparkle framework.
- [x] Commit `feat: add Sparkle in-app updates and native controls`.

### Task 3: 签名发布与真实演练

**Files:** Create `scripts/update-feed.py`, `scripts/tests/test_update_feed.py`; modify package/publish scripts, CI/Release workflows, README, releasing documentation and release notes.

**Interfaces:** Consumes compiled app + ZIP and public key. Produces signed `dist/appcast.xml`, checksum coverage and a verified set of four Release assets.

- [ ] Write Python integration tests using temporary real archive inputs for appcast generation/validation, malformed metadata, absent/mismatched keys, tampered archive, exact fixed HTTPS download URL and stable versions. Run `python3 -m unittest discover -s scripts/tests -p 'test_update_feed.py'`, expect missing module/command failure.
- [ ] Implement generation via Sparkle signing tools and fail-closed validation. Extend scripts to upload/download/compare appcast and validate signatures. Pin tool provenance to resolved Sparkle package.
- [ ] Update new release version, installation instructions and signing-secret setup; retain previous releases unchanged.
- [ ] Run Python, release-tag, Core, bridge and editor suites; `make release` with local signing credentials, expected verified Universal artifact and feed.
- [ ] Exercise an isolated app against a local feed, including signature rejection and successful download/install/relaunch. Record exact limits if the environment prevents this.
- [ ] Dispatch whole-branch reviewer; fix important findings with regression tests.
- [ ] Commit `feat: publish signed Sparkle update feeds from GitHub Releases`.

## Execution

User approved direct native execution in this chat. Reuse the existing clean checkout on `codex/github-release-updater`; no additional worktree is needed. Implement without another plan approval prompt. Any public-source visibility change or production release remains a separate final action after a concrete tested result exists.
