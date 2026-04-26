# Roadmap

Sprig 1.0 ships GUI shells for macOS and Windows in parallel. The engine and `sprigctl` CLI are first-class on macOS, Linux, and Windows from day 1. Linux GUI shell is post-1.0. See ADR 0054 for the strategic decision and ADR 0055 for the Windows GUI stack choice.

## Platform tier

| Surface | M0 | M1 | M2 | M3 | M4 (MVP) | M5 | M6 | M7 | M8 | M9 (1.0) |
|---|---|---|---|---|---|---|---|---|---|---|
| Engine + `sprigctl` (macOS / Linux / Windows) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| macOS GUI shell | — | — | alpha | task windows | merge UI | branching | submodules+LFS | AI | beta | 1.0 |
| Windows GUI shell | — | — | research | swift-cross-ui foundations | merge UI | branching | submodules+LFS | AI | beta | 1.0 |
| Linux GUI shell | — | — | — | — | — | — | — | — | — | post-1.0 |

CI required-green on every PR: `ci-macos`, `ci-linux` (full test suite on `packages/` + `cli/`), `ci-windows` (full test suite on `packages/` + `cli/`). Once Windows-shell work begins (M2-Win), the Windows CI matrix expands to cover the Explorer extension build + the swift-cross-ui app build.

## Milestones

The macOS-shell and Windows-shell tracks share most engineering work — the engine, the parsers, the `RepoState`/`TaskWindowKit` view-model layer. Per-shell work is concentrated in: the file-manager extension, the IPC adapter (XPC ↔ named pipes), the installer + updater, and the GUI framework (SwiftUI + AppKit ↔ swift-cross-ui).

**Track legend**: `🍎 Mac` (macOS-shell only), `🪟 Win` (Windows-shell only), `🌐 Engine` (cross-platform engine / CLI / shared view-model code).

### M0 — Foundations

🌐 Docs, CI matrix (macOS + Linux full tests + Windows full tests), SPM skeleton, ADRs 0001–0055 accepted. Contributor onboarding usable end-to-end.

### M1 — Read-only prototype *(in progress)*

🌐 `GitCore.Runner` + `CatFileBatch` + `PorcelainV2Parser` + `LogParser`. `WatcherKit.FSEventsWatcher` (macOS), `WatcherKit.PollingFileWatcher` (portable, used on Linux/Windows today). `sprigctl` subcommands: `version`, `status`, `watch`, `repos`, `log`. Validates 100k-file perf budget via benchmarks (pending).

### M2 — Shell integration alpha (parallel tracks)

- 🍎 **M2-Mac — FinderSync alpha**: SprigAgent LaunchAgent, XPC protocol, FinderSync extension with overlay badges and the MVP-10 right-click verbs (clone, status, commit, push, pull, fetch, branch-switch, stage/unstage, diff, log). Sheets, not full task windows yet.
- 🪟 **M2-Win — Explorer shell-extension alpha**: research spike on `IShellIconOverlayIdentifier` (15-overlay-slot competition with OneDrive/Dropbox), `IContextMenu` plumbing, named-pipe IPC to a Windows Service host of SprigAgent. `docs/research/windows-shell-apis.md` lands here as the M2-Mac equivalent of `docs/research/macos-finder-apis.md`. By the end of M2-Win, overlay badges + the MVP-10 verbs work in Explorer.

The two M2 sub-milestones can run sequentially (Mac first, Win second) or in parallel if the Windows expert is available — engineering plan decides per-PR. The `IPCSchema` package is shared across both.

### M3 — First task windows (parallel tracks)

- 🍎 **M3-Mac**: SwiftUI + AppKit task windows for CommitComposer, LogBrowser, DiffViewer, BranchSwitcher, CloneDialog, Preferences.
- 🪟 **M3-Win**: same task windows in swift-cross-ui (per ADR 0055). Reuses the view-model code from `TaskWindowKit` and `RepoState`. Per-window tweaks for Windows-native interaction conventions (menu placement, keyboard shortcuts).

### M4 — MergeConflictResolver (MVP gate, parallel tracks)

- 🍎 **M4-Mac**: 3-way merge view, conflict list, hunk-level accept/reject, snapshot safety net. macOS-specific high-density text rendering via `NSTextView`.
- 🪟 **M4-Win**: same 3-way merge view in swift-cross-ui. Open question deferred to M4 start: whether the Windows version uses a swift-cross-ui-native text view or drops to native Win32 for the diff pane.

🎯 **MVP ships here** on both shells.

### M5 — Rebase + advanced branching

🌐 RebaseInteractive, cherry-pick, revert, tag, stash. Implemented once in shared view models; rendered in both shells.

### M6 — Submodules + LFS first-class

🌐 SubmoduleManager, LFS install flow, `git subtree` import wizard.

### M7 — AI integration

🌐 Merge suggestions, commit-message drafting, PR description drafting. Ollama one-click installer (with platform-specific install commands per OS).

### M8 — Beta

🌐 Perf budgets verified in CI on both macOS and Windows (Linux for engine-only). a11y pass on both shells. Localization scaffolding (`String(localized:)` cross-platform).

### M9 — 1.0

- 🍎 **macOS**: signed/notarized DMG, Sparkle appcast, Homebrew Cask submission.
- 🪟 **Windows**: signed MSIX, winget manifest submission, WinSparkle (or chosen equivalent — see open question in ADR 0055) appcast.
- 🌐 **Linux**: source release tag with build instructions; engine + CLI usable. GUI shell explicitly out of scope at 1.0 (see ADR 0054).
- Docs site at `docs.sprig.app` (per ADR 0045).

## Risks specific to the dual-shell commitment

- **Calendar slip**: each macOS-shell milestone needs a Windows-shell counterpart. Worst case (strict serialization), 1.0 takes ~2× the engineering calendar of a macOS-only 1.0. Mitigation: invest hard in shared view-model code in `TaskWindowKit` so the per-shell delta is small.
- **Contributor recruiting**: Windows-shell work needs Windows-native expertise (COM, MSIX, Windows Service authoring). The maintainer's BDFL coverage probably can't fill this alone. ADR 0017's "open up steering when 3+ steady contributors emerge" applies — finding a Windows-shell-savvy collaborator is on the M2 critical path.
- **swift-cross-ui maturity**: framework is younger than SwiftUI on macOS. ADR 0055 documents the WinUI 3 fallback. Re-evaluate at the start of M3-Win.
- **Distribution doubling**: macOS DMG + Homebrew Cask **and** Windows MSIX + winget. Both pipelines need release engineering and code-signing infrastructure.

See `docs/planning/risk-register.md` for the full risk list (engine + per-shell risks combined).
