# Architecture Overview

Sprig is structured as **engine + per-OS shells**. The engine is portable Swift that runs first-class on macOS, Linux, and Windows. Shells are platform-specific GUI surfaces that drive the engine over IPC. The macOS shell ships at 1.0; the Windows shell is also a 1.0 deliverable (ADR 0054). Linux shell is post-1.0.

This doc is the entry point for new contributors. Deeper-dive companion docs:

- [`modules.md`](modules.md) — every Swift package, what it does, what it depends on.
- [`git-backend.md`](git-backend.md) — how we invoke git, parse output, and cache objects.
- [`fs-watching.md`](fs-watching.md) — FSEvents, polling, future native watchers, the EventCoalescer, the fsmonitor hook plan.
- [`shell-integration.md`](shell-integration.md) — Finder + Explorer extensions, IPC.
- [`performance.md`](performance.md) — budgets, benchmarks, profiling.
- [`security.md`](security.md) — credentials, signing, hook trust.
- [`ai-integration.md`](ai-integration.md) — AIKit provider abstraction.
- [`cross-platform.md`](cross-platform.md) — three-tier rules; how the engine stays portable.

The master plan at `/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md` is the long-form authoritative source for design rationale and ADR cross-references.

## High-level diagram

```
┌─────────────────────────────────────────────────────────────────┐
│              OS file manager  (Finder / Explorer)               │
│  ┌────────────────────────┐    ┌────────────────────────┐       │
│  │  SprigFinder           │    │  SprigExplorer (Win)   │       │
│  │  FinderSync extension  │    │  IShellIconOverlay-    │       │
│  │  (overlay badges +     │    │  Identifier +          │       │
│  │   context menu)        │    │  IContextMenu (COM)    │       │
│  └──────────┬─────────────┘    └──────────┬─────────────┘       │
└─────────────┼────────────────────────────┼──────────────────────┘
              │ XPC                        │ Named pipes
              ▼                            ▼
       ┌──────────────────────────────────────────────┐
       │           SprigAgent (background)            │
       │   LaunchAgent on macOS · Windows Service     │
       │                                              │
       │   ┌─────────────────────────────────────┐    │
       │   │  CommandRouter                      │    │
       │   │  serializes mutating git ops/repo   │    │
       │   └──────────────┬──────────────────────┘    │
       │                  │                           │
       │   ┌──────────────┼──────────────┐            │
       │   │              ▼              │            │
       │   │  ┌────────────────────┐     │            │
       │   │  │  RepoState (per    │     │            │
       │   │  │  repo: dirty-set,  │     │            │
       │   │  │  badge trie, etc.) │     │            │
       │   │  └────────┬───────────┘     │            │
       │   │           │                 │            │
       │   │           ▼                 │            │
       │   │  ┌────────────────────┐     │            │
       │   │  │  WatcherKit        │     │            │
       │   │  │  FSEvents (Mac)    │     │            │
       │   │  │  Polling (portable)│     │            │
       │   │  │  ReadDirChanges-W  │     │            │
       │   │  │  (Win; planned)    │     │            │
       │   │  └────────────────────┘     │            │
       │   │                             │            │
       │   │  ┌────────────────────┐     │            │
       │   │  │  GitCore           │     │            │
       │   │  │  Runner +          │     │            │
       │   │  │  CatFileBatch +    │     │            │
       │   │  │  PorcelainV2Parser │     │            │
       │   │  │  + LogParser       │     │            │
       │   │  └────────┬───────────┘     │            │
       │   │           │                 │            │
       │   └───────────┼─────────────────┘            │
       │               ▼                              │
       │  ┌─────────────────────────────────────┐     │
       │  │  Other Tier-2 adapters              │     │
       │  │  CredentialKit, NotifyKit, UpdateKit│     │
       │  │  LauncherKit, TransportKit          │     │
       │  └─────────────────────────────────────┘     │
       └──────────────────┬───────────────────────────┘
                          │ Foundation.Process spawn
                          ▼
                ┌─────────────────────┐
                │  system `git`       │
                │  (+ optional        │
                │   git-lfs, gh, ssh) │
                └─────────────────────┘
```

## Three tiers (ADR 0048, 0053)

The engine is organized so adding a platform shell is *additive*, not a refactor:

1. **Tier 1 — portable core** (`packages/{GitCore, RepoState, ConflictKit, AIKit, LFSKit, SubmoduleKit, SubtreeKit, SafetyKit, IPCSchema, PlatformKit, DiagKit, StatusKit, TaskWindowKit, UIKitShared}/`). Pure Swift + Foundation. Compiles and tests on macOS, Linux, Windows every PR.
2. **Tier 2 — platform adapters** (`packages/{WatcherKit, CredentialKit, NotifyKit, UpdateKit, LauncherKit, TransportKit, AgentKit}/`). Protocol in `Sources/<Pkg>/` (portable); native implementations in `Sources/{Mac,Linux,Windows}/`. Where a portable fallback exists (e.g. `PollingFileWatcher`) it lives alongside the protocol.
3. **Tier 3 — platform shells** (`apps/macos/`, `apps/windows/`, `apps/linux/`). Full rewrite per OS. macOS populated; Windows is a 1.0 deliverable and currently a stub README; Linux is post-1.0.

## Data flow at a glance

A representative read: **user opens a Finder window of a repo** (or Explorer on Windows).

1. The shell extension queries the agent over IPC: "what badges for these paths?"
2. The agent looks up its in-memory `RepoState` (per repo, keyed by path) and answers from a path trie. If the repo isn't tracked yet, the agent triggers a `git status --porcelain=v2 -z` via `GitCore.Runner`, parses with `PorcelainV2Parser`, populates `RepoState`, and answers.
3. The shell extension renders badges. Total round-trip target: <100 ms (ADR 0021 perf budget).
4. While the user is browsing, `WatcherKit` is watching the repo's working-tree paths. On change, events flow through `EventCoalescer` (per ADR 0024 Sprig is the single source of truth for filesystem state and drives `core.fsmonitor` so `git status` becomes O(changed paths) on subsequent invocations).
5. When `RepoState`'s view of the repo changes, the agent pushes a delta to the shell extension; badges update without polling.

A representative write: **user right-clicks a file and chooses "Stage" from the Sprig submenu.**

1. The shell extension sends a "stage \<path\> in \<repo\>" command over IPC.
2. The agent's `CommandRouter` serializes the operation onto the repo's queue (no two mutating ops run concurrently for the same repo).
3. `GitCore.Runner` runs `git add <path>`. Output is captured; non-zero exit → error surfaced back through IPC; success → `RepoState` invalidates and re-fetches affected paths.
4. The shell extension receives an updated badge for the staged path.
5. If the operation is destructive (force-push, hard reset, etc.), `SafetyKit` writes a snapshot ref under `refs/sprig/snapshots/...` *before* the dangerous op (ADR 0033) so the user has 24-hour undo.

## What exists today (as of this writing)

Implemented and CI-required-green on macOS / Linux / Windows:

- `GitCore.Runner`, `GitCore.CatFileBatch`, `GitCore.GitVersion`, `GitCore.GitError`.
- `GitCore.PorcelainV2Parser` and `GitCore.LogParser`.
- `PlatformKit.FileWatcher` protocol, `WatchEvent` model, `EventCoalescer`.
- `WatcherKit.MockFileWatcher` (test fixture), `WatcherKit.PollingFileWatcher` (portable), `WatcherKit.FSEventsWatcher` (macOS).
- `sprigctl` CLI with subcommands: `version`, `status`, `watch`, `repos`, `log`.
- All Tier-2 protocol shells exist for `Credential / Notify / Update / Launcher / Transport / Agent`. Native impls are stubs (`fatalError("not implemented")`) until their owning milestone activates.

Not yet started:

- The macOS app shell (`apps/macos/SprigApp/`, `apps/macos/SprigAgent/`, `apps/macos/SprigFinder/`) — milestone M2-Mac onward.
- The Windows app shell (`apps/windows/`) — milestone M2-Win onward.
- `RepoState` real implementation (currently a stub package).
- `ConflictKit`, `SubmoduleKit`, `SubtreeKit`, `LFSKit`, `AIKit` — stub packages awaiting their feature milestones.

See [`../planning/roadmap.md`](../planning/roadmap.md) for milestone-by-milestone scope.

## Key invariants worth knowing before reading deeper docs

- **Defer to the user's `git`.** No libgit2. `git` does the work; we marshal arguments and parse output. (ADR 0023.)
- **Tier 1 packages compile on Linux Swift 6.3 every PR.** That's how we catch macOS/Apple-API leakage before it ships.
- **All git invocation goes through `GitCore.Runner` or `GitCore.CatFileBatch`.** No ad-hoc `Process()` in feature code.
- **All IPC messages are `Codable` structs in `IPCSchema`.** Wire format is XPC-on-macOS / named-pipes-on-Windows / D-Bus-or-UNIX-socket-on-Linux, but the schema is one Swift type tree.
- **Force-pushes always use `--force-with-lease --force-if-includes`** (ADR 0052). Raw `--force` is never emitted.
- **Destructive ops snapshot first** under `refs/sprig/snapshots/...` (ADR 0033).
