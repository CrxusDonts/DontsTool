# Finder Action Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline.

**Goal:** Make Finder reveal visible on file results without changing Enter behavior.

**Architecture:** Reuse existing secondary actions and native NSWorkspace reveal implementation. Put an independent accessory button beside the primary row button; pass the row-specific secondary-execution closure from LauncherPanelView. Keep keyboard and action-menu paths intact.

**Tech Stack:** SwiftUI, AppKit, existing Core providers.

**Spec:** ../specs/2026-11-15-finder-action-design.md

## Constraints and review focus

- Preserve unrelated local work; no Git delivery. Local restart authorized.
- No nested buttons, no simultaneous primary/secondary invocation, no wrong selected-row target on hover.
- Reserve accessory layout space; hide decorative controls from accessibility when unavailable; retain main-button label and selection trait.
- Both Spotlight files and direct paths must reveal the selected file, not just open a default application.

## Tasks

- [x] Add visible accessory, contextual help and native file-row snapshots; update Chinese action labels and README.
- [x] Verify existing action tests and native presentation; inspect snapshots and request a scoped review.
- [x] Build Universal 0.2.0 build 8, verify local identity and bytes, install/restart.
- [x] Execute the button on a known local file and verify Finder selects it.

## Verification

- 28 focused Core tests passed (`/tmp/dontstool-finder-action-core.log`); 19 native/bridge tests passed (`/tmp/dontstool-finder-action-native.log`). Existing quick-open test additionally verifies its secondary action reveals the same full path without another open call.
- Reviewed native light/dark file-row snapshots at `build/launcher-previews/launcher-file-{dark,light}.png`; independent scoped review found no blocking issue.
- Universal Release built (`/tmp/dontstool-finder-action-release.log`), installed 0.2.0 build 8; stable signing requirement, both architectures and staged/installed byte equality verified.
- CUA entered the actual repository README path, found the distinct folder button, clicked it, and observed Finder's DontsTool window with README.md selected at the exact requested URL. No primary open action was invoked by the accessory path.
- Unselected-row hover and VoiceOver navigation were statically reviewed but not exercised end to end. Existing keyboard routing remains unchanged.
- No commit, push or public release in this task.
