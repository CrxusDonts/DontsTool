# Explicit File Search Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline. Preserve existing unrelated uncommitted work.

**Goal:** Make ordinary launcher queries avoid Spotlight subprocesses and delayed file-search status; search files only through `file`.

**Architecture:** Add ToolProvider.supportsGlobalSearch with a true default. SearchCoordinator filters global providers by this flag. FileProvider opts out, advertises file, and validates scoped requests. Keep QuickOpen, settings persistence and cancellation intact.

**Tech Stack:** Swift 6, AppKit/SwiftUI, existing Spotlight service.

**Spec:** ../specs/2026-11-15-explicit-file-search-design.md

## Global constraints

- No runtime dependencies, signature identity changes, commits, pushes or releases.
- Keep existing disabled-provider/file-search preferences and website-prefix priority.
- Local reinstall/restart is already authorized.

## Review focus

- Ordinary queries produce no file command, no searchingFiles status and no slow phase.
- Uppercase FILE and names containing spaces route to files; whitespace-only arguments start no command.
- Disabled file searching remains disabled; another provider's keyword cannot query files.
- Bare file has a useful prompt; empty explicit searches do not fall back to public web search.
- Complete paths still use QuickOpen and do not start Spotlight.

## Task 1: Routing and behavior

Files: Models.swift, SearchCoordinator.swift, FileProvider.swift; FileProviderTests.swift, SearchCoordinatorTests.swift.

- [x] Add regression tests using a real FileProvider and mock command runner for the review focus; adapt former global file tests to explicit requests.
- [x] Run focused Core tests and confirm behavior failures before implementation.
- [x] Add capability/routing guards; update settings descriptions, launcher empty hint and README.
- [x] Run full Core tests and native tests; review diff independently.

## Task 2: Deliver locally

- [x] Build Universal Release 0.2.0 build 7, verify stable local signature and installed bytes, replace and restart.
- [x] Verify native ordinary search and explicit file mode; record actual results.

## Verification

- Real behavior RED confirmed command execution during global queries and missing explicit keyword support: `/tmp/dontstool-explicit-file-behavior-red.log`.
- Final Core suite: 296 tests in 39 suites passed (`/tmp/dontstool-explicit-file-final-core.log`). Native suite: 19 tests in 4 suites passed (`/tmp/dontstool-explicit-file-native.log`).
- Independent read-only review completed; fixed misleading README table and file empty-state hints for a custom website group also named file. Model now retains the actual KeywordRoute, with the visible badge derived from it.
- Universal Release 0.2.0 build 7 built (`/tmp/dontstool-explicit-file-release.log`), stable signing requirement and all staged/installed bytes verified. Installed and restarted `/Applications/DontsTool.app`; no Git commit/push/release.
- Native UI: ordinary README produced only a web-search action and no file-search status/results; bare file showed input guidance; file README completed with 12 file results and no web fallback. Complete-path direct opening was verified through the real coordinator + QuickOpen + FileProvider integration test with zero Spotlight-runner arguments.
- Existing local website configuration has no file-prefix collision. Routing priority remains compatible with older configurations; file-search disabled preferences are retained.
