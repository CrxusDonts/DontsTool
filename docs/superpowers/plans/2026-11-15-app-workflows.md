# Application Workflows Implementation Plan

> **For agentic workers:** Use inline integration with explicitly scoped parallel tasks. Read ../specs/2026-11-15-app-workflows-design.md.

**Goal:** Implement the three user-authorized workflows and install a verified local build.

**Architecture:** Two keyword-only providers reuse registry/results/actions. IDEA parsing and launching have injectable boundaries. Gemini separates a tested handoff service from a target-bound AppKit/AX adapter. Translation keeps the single card and repairs the long-hold/selection pipeline.

**Tech Stack:** Swift 6, AppKit/SwiftUI, Foundation XML, existing Core tests.

## Constraints and review focus

- No automatic network submission during typing; no question/selection logging, clipboard mutation or guessed prompt URL.
- Gemini validates empty new conversation, exact prompt, foreground and target before submit; preserve existing drafts and prevent repeats.
- IDEA uses current installed version, bounded XML/background cache; no full disk scan or arbitrary command interpolation.
- Translation must preserve short right clicks and cancel on movement/focus; show failure rather than silent no-op.
- Existing preferences, stable local signature and unrelated changes remain intact. Restart already authorized; do not ask again.

## Tasks

- [x] IDEA discovery/provider/native launcher and isolated behavior tests (agent ownership: new IDEProjects and IDEProject files only).
- [x] Translation AX/gesture/card failure pipeline and regression tests (agent ownership: Selection/*, RightPressGesture, related tests, SelectionTranslationView).
- [x] Gemini local capability research (agent read-only), Core workflow/provider tests, native AX adapter (main).
- [x] Integrate ProviderID migration, registry, settings hints and documentation; export changed translation interaction reference if needed.
- [x] Generate project, run focused RED/GREEN and final full Core/Native suites; scoped independent review.
- [x] Build Universal, sign with existing local identity, replace installation and restart; verify installed binary.
- [ ] After manual unlock, complete native Gemini send, IDEA project open, short/long right-click and language-pack preparation/real translation checks.

## Verified code and local installation

- Final Core: 329 tests in 45 suites passed (`/tmp/dontstool-app-workflows-final-core.log`). Final Native: 63 tests in 9 suites passed (`/tmp/dontstool-app-workflows-native-verified.log`).
- Independent reviews fixed IDEA stale-action enable/cancel checks, translation read completion after dismissal, and language-preparation stale callbacks. Gemini has per-handoff Escape cancellation and wall-clock limits, with exact target/prompt verification and one submit attempt.
- Final Universal Release built (`/tmp/dontstool-app-workflows-release-final.log`), installed 0.2.0 build 10 at `/Applications/DontsTool.app`; both architectures, strict local signature, previous signing requirement and all staged/installed file bytes verified. Executable SHA256: 50112343d07b7b5642508f3db653465559d898218eec6548db7bfe11b8270f93.
- Only GUI preflight: actual installed Gemini exposes a writable composer, new-chat button and stable submit identifier; a disposable fixed prompt was filled then cleared, not sent. IDE recent-project parsing found six valid current-version directories.
- CUA on candidate build9 and final build10 both reported the Mac locked. Requested manual unlock asynchronously; no password requested, no lock bypass. Thus no claim that final Gemini sending, IDEA activation, real right-click or on-device translation has passed native acceptance.
- English/Chinese availability checked as supported but not installed; language download needs the explicit preparation window after unlock. System route is default when no complete custom API configuration exists.
- No commit/push or public release performed. Await manual unlock to finish acceptance.
