# Fluid Launcher Implementation Plan

> For agentic workers: use superpowers:executing-plans for main-agent integration; independent search, content-service and animation tasks are delegated with explicit file ownership.

**Goal:** Improve the native launcher discovery, context actions and motion, then install the verified result locally.

**Architecture:** Keep providers and tool windows. Add cached application search documents, persistent ordering, a small explicit-paste content service and attached-content model state. Keep window transitions in AppKit and selection/content transitions in SwiftUI.

**Tech Stack:** Swift 6, SwiftUI, AppKit, FSEvents; no new runtime dependencies.

**Spec:** ../specs/2026-11-15-fluid-launcher-design.md

## Global constraints

- Preserve unrelated uncommitted changes and the existing multiwindow tools.
- No clipboard polling, new external plugin runtime or implicit network execution.
- Retain the existing local signing certificate; user permits installation/restart without repeated confirmation.
- Keep keyboard/IME behaviour and accessibility settings intact.

## Tasks

- [x] Reproduce and fix live indexing with real filesystem events and fresh plist metadata.
- [x] Verify RED/GREEN for cached pinyin/abbreviation matching and recent/frequency/name ordering.
- [x] Verify explicit-content descriptor/provider behaviour and attached model cancellation/filtering.
- [x] Connect paste field editor, application activation tracking and sort controls.
- [x] Implement semantic native colours, continuous selection, contextual footer and interruptible window motion.
- [x] Export usable local HTML and check all visible copy against implemented behaviour.
- [x] Run Core/Bridge suites, native view snapshots, keyboard/paste/reopen checks and independent review.
- [x] Build Universal release, verify stable identity, replace installation, restart and verify running binary.

## Review focus

Pasted private source must never become a global query; in-progress search must not overwrite context actions; copied input must preserve whitespace; disabled providers must remain disabled; stale animation completion must never close a reopened panel; all routes must remain keyboard accessible.

## Verified local result

- 288 Core tests passed: `/tmp/dontstool-fluid-localized-core.log`.
- 19 Bridge tests passed, including native snapshots, paste variants, rapid reopen, display-link lifecycle and early disposal: `/tmp/dontstool-motion-final-native.log`.
- Universal Release built successfully: `/tmp/dontstool-motion-final-release.log`.
- Installed 0.2.0 build 6 at `/Applications/DontsTool.app`; both architectures, strict signature, existing signing requirement and all staged/installed file bytes verified.
- Native UI confirmed `wx` finds 微信, `zd` finds 终端, arrow selection/⌘K/Esc work, explicit JSON paste offers only the JSON action, and execution opens an independent editor preserving the original string. Closed the disposable QA window.
- The global double-Option gesture was not reverified through automation; the UI input API did not support its modifier-only key token. Existing modifier detector tests remain green.
- Local installation only; this iteration was not committed, pushed or publicly released.
