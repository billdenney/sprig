# Roadmap

Mirrors §6 of the master plan. The macOS-shell-first sequence below is correct for engine + macOS-shell milestones today; **Windows-shell parallels (M2-Win, M3-Win, M4-Win, M9 dual ship) are an explicit 1.0 deliverable** and will be interleaved into this list in the next planning pass (PR following this one). Linux GUI shell remains post-1.0.

## Platform tier

| Surface | M0 | M1 | M2 | M3 | M4 (MVP) | M5–M7 | M8 | M9 (1.0) |
|---|---|---|---|---|---|---|---|---|
| Engine + `sprigctl` (macOS / Linux / Windows) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| macOS GUI shell | — | — | alpha | task windows | merge UI | feature work | beta | 1.0 ship |
| Windows GUI shell | — | — | research | (parallel) | (parallel) | (parallel) | beta | 1.0 ship |
| Linux GUI shell | — | — | — | — | — | — | — | post-1.0 |

CI required-green on every PR: `ci-macos`, `ci-linux` (`packages/` + tests), `ci-windows` (full test suite). Once Windows-shell work begins, the Windows CI matrix expands to cover the Explorer extension build too.

## Milestones (engine + macOS-shell sequence)

- **M0 — Foundations**: Docs, CI (macOS + Linux full tests + Windows full tests), SPM skeleton, ADRs 0001–0053 accepted. Contributor onboarding usable.
- **M1 — Read-only prototype**: FSEvents watcher (macOS), PollingFileWatcher (portable), porcelain-v2 parser, `sprigctl` CLI (status / watch / repos / log). Validates 100k-file perf budget. *(In progress — most pieces landed; benchmarks pending.)*
- **M2 — SprigAgent + FinderSync alpha** (macOS shell): LaunchAgent, XPC, overlay badges, MVP-10 context-menu actions (sheets, not task windows yet).
- **M3 — First task windows** (macOS shell): CommitComposer, LogBrowser, DiffViewer, BranchSwitcher, CloneDialog, Preferences.
- **M4 — MergeConflictResolver** (macOS shell, MVP gate): 3-way merge view, conflict list, hunk accept/reject, snapshot safety net. **MVP ships here.**
- **M5 — Rebase + advanced branching**: RebaseInteractive, cherry-pick, revert, tag, stash.
- **M6 — Submodules + LFS first-class**: SubmoduleManager, LFS install flow, `git subtree` import wizard.
- **M7 — AI integration**: Merge suggestions, commit-message drafting, PR description drafting. Ollama one-click installer.
- **M8 — Beta**: Perf budgets verified in CI; a11y pass; localization scaffolding.
- **M9 — 1.0**: Signed/notarized DMG + Homebrew Cask **and** signed MSIX + winget; Sparkle appcast for macOS, WinSparkle (or chosen equivalent) for Windows; docs site; launch.

The Windows-shell milestones (M2-Win research → M3-Win swift-cross-ui task windows → M4-Win merge UI → joining the standard M5–M9 progression) will be interleaved in the next planning revision. They share the engine + view-model code; the per-shell work is the OS-specific extension, IPC adapter, installer, updater, and platform polish.
