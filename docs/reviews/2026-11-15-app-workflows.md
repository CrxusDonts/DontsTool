# Application workflow review

Implemented: keyword-only Gemini and IDEA actions; two-second selection translation/read feedback; default local system translation with an explicit language-pack preparation window.

Reviewed and fixed: (1) generated IDEA actions surviving disable/cancel; (2) late AX read reopening a dismissed card and sending text; (3) stale language-preparation session callbacks modifying a newer request. Gemini also uses a stable full application path, bounded non-history AX inspection, draft protection, exact text verification, foreground/window checks, per-handoff Escape cancellation and one submit attempt.

Verification: 329 Core + 63 Native tests green. Universal build10 installed and byte/signature checked. Light/dark native language-window snapshots were inspected without triggering download.

Pending: actual Gemini send/new-chat acceptance, IDEA window activation, physical/browser short and long right-click behavior, Apple language-pack download and real translation. The Mac is locked; CUA explicitly requires manual unlock. No passing claim is made for these pending checks. See the implementation plan for log paths and installed hash.
