# Architecture Decision Records (ADRs)

Sprig uses [MADR](https://adr.github.io/madr/) format. Each decision lives as a numbered markdown file in this directory.

Status values: `proposed`, `accepted`, `superseded-by-NNNN`, `deprecated`.

New ADRs: copy `0000-template.md`, pick the next free number, add an entry to the table below, and link from your PR.

## Index

| #    | Title                                                                      | Status   |
|------|----------------------------------------------------------------------------|----------|
| 0001 | Use system git binary for all git operations                               | accepted |
| 0002 | License — Apache-2.0                                                       | accepted |
| 0003 | Primary language — Swift                                                   | accepted |
| 0004 | Filesystem watcher — FSEvents-based with per-repo incremental index        | accepted |
| 0005 | Enable core.fsmonitor via our watcher                                      | accepted |
| 0006 | Modular SwiftPM packages per subsystem                                     | accepted |
| 0007 | AI integration is optional, pluggable, provider-agnostic                   | accepted |
| 0008 | Default to Scalar-style modern git settings                                | accepted |
| 0009 | Distribution — direct notarized DMG with Sparkle                           | accepted |
| 0010 | Minimum macOS — 14 Sonoma floor with opportunistic 15 APIs                 | accepted |
| 0011 | UI framework — SwiftUI-first with AppKit escape hatches                    | accepted |
| 0012 | MVP scope — thin MVP plus merge UI                                         | accepted |
| 0013 | AI providers — Anthropic, OpenAI, Ollama, Apple on-device                  | accepted |
| 0014 | Telemetry — opt-in only, local-first                                       | accepted |
| 0015 | Sustainability — pure FOSS + GitHub Sponsors                               | accepted |
| 0016 | Project name — Sprig                                                       | accepted |
| 0017 | Governance — BDFL transitioning to open steering                           | accepted |
| 0018 | Distribution channels — Homebrew Cask + direct download at 1.0             | accepted |
| 0019 | Badge icon set — full 10 with user-selectable reveal level                 | accepted |
| 0020 | Context menu layout — common flat, advanced in submenu                     | accepted |
| 0021 | Performance budget — Linux-kernel scale                                    | accepted |
| 0022 | Non-local volumes — best-effort with polling fallback                      | accepted |
| 0023 | Git invocation — shell out only, no libgit2                                | accepted |
| 0024 | Our FSEvents watcher is single source of truth, drives core.fsmonitor      | accepted |
| 0025 | Repo discovery — user-added roots plus learn-as-you-go                     | accepted |
| 0026 | Scalar-style defaults — perf bundle, safety hardening, maintenance, partial clone | accepted |
| 0027 | Merge UI — built-in 3-way view with external-tool delegation option        | accepted |
| 0028 | AI merge assistance — suggest-only with hunk preview                       | accepted |
| 0029 | LFS install flow — detect plus one-click Homebrew                          | accepted |
| 0030 | Finder-first architecture — no main app file tree                          | accepted |
| 0031 | Submodules — badges plus right-click plus SubmoduleManager window          | accepted |
| 0032 | Git extension support plan                                                 | accepted |
| 0033 | Destructive-op safety — tiered with snapshot refs                          | accepted (amended 2026-05-02 to add visible Recover task window per §13.3-A) |
| 0034 | No menu-bar helper                                                         | accepted |
| 0035 | AI feature scope for M7                                                    | accepted |
| 0036 | AI privacy default — local-first with per-action cloud confirmation        | accepted |
| 0037 | AI prompt storage — in-repo versioned markdown                             | accepted |
| 0038 | AI evaluation harness                                                      | accepted |
| 0039 | Onboarding — adaptive                                                      | accepted |
| 0040 | Keyboard-first with command palette                                        | accepted |
| 0041 | Multi-identity profiles — first-class                                      | accepted |
| 0042 | Accessibility and localization — full a11y, English at 1.0                 | accepted |
| 0043 | Credentials — Keychain-backed helper honoring existing tools               | accepted |
| 0044 | Commit signing — SSH signing in onboarding, default on                     | accepted |
| 0045 | Docs platform — DocC plus Astro Starlight                                  | accepted |
| 0046 | Release cadence — monthly stable plus weekly beta                          | accepted |
| 0047 | Git detection and install bootstrap                                        | accepted |
| 0048 | Cross-platform extensibility rules                                         | accepted |
| 0049 | Modern git config defaults                                                 | accepted |
| 0050 | Hook security model — trust prompt per-repo                                | accepted |
| 0051 | Stacked-PR workflow as first-class                                         | accepted |
| 0052 | Force-push aliasing — always --force-with-lease --force-if-includes        | accepted |
| 0053 | Day-1 cross-platform scaffolding commitment                                | accepted |
| 0054 | 1.0 platform tier — macOS + Windows GUI shells, Linux engine-only          | accepted (partially supersedes 0009, 0030, 0034) |
| 0055 | Windows GUI stack — swift-cross-ui                                         | accepted |
| 0056 | External-git-agent awareness — watch `.git/`, defer on lock files          | accepted |
| 0057 | "Commands" panel — default-on, in every task window                        | accepted |
| 0058 | Transient-flag chips on action buttons — tiered by op stakes               | accepted |
| 0059 | FinderSync resilience — heartbeat, sprigctl finder CLI, iCloud Drive guards | accepted |
| 0060 | Windows shell extension hardening                                          | accepted |
| 0061 | Sub-hunk / region staging in CommitComposer                                | accepted |
| 0062 | Stacked-PR UI — right-click verbs + Stack Manager task window              | accepted |
| 0063 | Forge integration — task-window verbs (no "PRs" tab)                       | accepted |
| 0064 | Auto-fetch — AC / metered / battery-aware backoff                          | accepted |
| 0065 | Stash safety — export `refs/stash` as patches before repo removal          | accepted |
| 0066 | Stale `index.lock` recovery flow (60s threshold + one-click clear)         | accepted |

ADRs 0001–0053 were ratified simultaneously in the initial scaffolding, based on the planning dialogue captured in the master plan file. Subsequent ADRs (0054+) follow the normal one-per-PR cadence.

ADRs 0057–0066 (and the 0033 amendment) were ratified together via maintainer Q&A on 2026-05-02 after a competitive review of 50+ git GUIs filtered through the Finder/Explorer-first invariant. See master plan §13 for the synthesis and the per-ADR ratification table.
