# Roadmap

Mirrors §6 of the master plan.

- **M0 — Foundations**: Docs, CI (macOS + Linux + Windows `packages/`), SPM skeleton, ADRs 0001–0053 accepted. Contributor onboarding usable.
- **M1 — Read-only prototype**: FSEvents watcher, porcelain-v2 parser, `sprigctl` CLI. Validates 100k-file perf budget.
- **M2 — SprigAgent + FinderSync alpha**: LaunchAgent, XPC, overlay badges, MVP-10 context-menu actions (sheets, not task windows yet).
- **M3 — First task windows**: CommitComposer, LogBrowser, DiffViewer, BranchSwitcher, CloneDialog, Preferences.
- **M4 — MergeConflictResolver (MVP gate)**: 3-way merge view, conflict list, hunk accept/reject, snapshot safety net. **MVP ships here.**
- **M5 — Rebase + advanced branching**: RebaseInteractive, cherry-pick, revert, tag, stash.
- **M6 — Submodules + LFS first-class**: SubmoduleManager, LFS install flow, `git subtree` import wizard.
- **M7 — AI integration**: Merge suggestions, commit-message drafting, PR description drafting. Ollama one-click installer.
- **M8 — Beta**: Perf budgets verified in CI; a11y pass; localization scaffolding.
- **M9 — 1.0**: Signed/notarized DMG, Sparkle appcast, Homebrew Cask, docs site, launch.
