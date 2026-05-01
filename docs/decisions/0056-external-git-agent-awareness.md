---
status: accepted
date: 2026-05-01
deciders: maintainer
consulted: —
informed: —
---

# 0056. External-git-agent awareness — watch `.git/`, defer on lock files, recurse submodules + linked worktrees

## Context

Sprig watches a working tree to update Finder/Explorer badges. But many user actions don't touch the worktree at all:

- **`git commit`** from a terminal — ref + index + reflog change in `.git/`; worktree byte-identical
- **`git fetch`** — `.git/FETCH_HEAD`, `.git/refs/remotes/*` change; worktree untouched
- **`git stash push`** — index + new ref under `.git/refs/stash`; worktree may be cleaned
- **A second GUI tool committing** — same as the first
- **A CI runner on the same machine** — runs git ops on its checkout, possibly the user's

If Sprig only watches the worktree, badges go stale immediately after any of these. ADR 0024 covers the *outgoing* direction (Sprig as `core.fsmonitor` source of truth for the user's git); this ADR covers the *incoming* direction (Sprig detecting external changes to react to).

The challenge is non-trivial because:

1. **Git's storage layout evolves**: loose refs, packed-refs, reftable (2.45+ opt-in) — all describe "where is `refs/heads/main` stored?"
2. **Git's writes aren't atomic at the filesystem layer**: `git commit` is `objects/` write → `<ref>.lock` rename → `index` rewrite → `logs/HEAD` append. A `git status` query observed mid-sequence sees inconsistent state.
3. **Submodules nest arbitrarily deep**: each submodule's `.git` is a *file* pointing to `<super>/.git/modules/<name>/`. Nested submodules nest the pointer chain.
4. **Linked worktrees** (`git worktree add`) use the same gitdir-pointer mechanism in the opposite direction: linked worktrees share an object store but have per-worktree `HEAD`/`refs/`.
5. **Lock-file events**: every git write creates `<file>.lock`, fsyncs, renames. The intermediate states are 2–3 events per write that don't represent state changes; reacting to them produces spurious refreshes.

## Decision

Sprig handles external git agents through five complementary mechanisms, all implemented in `GitCore.GitMetadataPaths` (Tier 1 portable, no platform APIs):

### 1. Watch `.git/` recursively, in addition to the worktree

The watcher subscribes to events under both the worktree and the resolved `.git/` directory. Storage-layout differences (loose refs vs packed-refs vs reftable) are absorbed transparently — any change inside `.git/` triggers the (filtered, debounced) refresh path.

### 2. Resolve `.git` files to their actual gitdir

`<worktree>/.git` may be either a directory (the simple case) or a *file* containing `gitdir: <path>`. The pointer form is used by:

- **Submodules**: `<super>/<sub>/.git` → `<super>/.git/modules/<sub>/`
- **Linked worktrees**: `<linked>/.git` → `<original>/.git/worktrees/<name>/`

`GitMetadataPaths.resolveGitDir(forWorktree:)` handles both. Pointer paths can be relative (resolved against the worktree) or absolute. We don't follow nested pointer chains — git's docs say they aren't supported.

### 3. Recursively discover submodules (including nested) and linked worktrees

- `GitMetadataPaths.submoduleWorktrees(at:runner:)` — runs `git submodule status --recursive` and returns absolute URLs for every submodule worktree (top-level *and* nested). Includes uninitialized submodules so callers can render the `submodule-init-needed` badge.
- `GitMetadataPaths.linkedWorktrees(at:)` — reads `<gitDir>/worktrees/*/gitdir` and returns each linked worktree's root URL.

The agent watches the worktree + `.git/` + every discovered submodule's `.git/` + every linked worktree's `.git/`. For a 5-level-deep submodule structure, that's 6 watch trees per top-level repo.

### 4. Filter lock and temp files at the per-event layer

`GitMetadataPaths.isLockOrTempPath(_:in:gitVersion:)` returns true for paths inside `.git/` that are git's transient artifacts:

- **`*.lock`** — atomic-write-rename pattern. The final rename to the non-`.lock` name is the event that matters; the intermediate `.lock` lifecycle is noise.
- **`objects/pack/tmp_*` and `objects/pack/.tmp-*`** — pack-write temps from `git fetch`/`git gc`/`git repack`.
- **`objects/incoming-*/`** — fetch staging directory in git 2.40+.

Filtering happens at the per-event layer (in the watcher's coalescer), so our watcher emits only "real" change events into RepoState.

### 5. Defer status refreshes while a git operation is in flight

`GitMetadataPaths.gitOperationInFlight(in:gitVersion:)` returns true when any of `index.lock`, `HEAD.lock`, `packed-refs.lock`, `config.lock`, or `shallow.lock` exists. The watcher's coalescer checks this before draining a tick: if a lock is present, defer the drain. Typical lock duration is <100 ms, so the cost is one tick of latency on the affected status update — not a user-visible delay. The benefit is correctness: we never query `git status` mid-mutation and never observe inconsistent state.

### 6. Version-aware hooks (reserved)

The four critical APIs accept an optional `GitVersion` parameter. Today the implementation ignores it — git ≥ 2.39 (Sprig's floor per ADR 0047) and the reftable format (auto-detected via `<gitDir>/reftable/` presence) are the only variables, and both are absorbed by the "watch `.git/` recursively + filter lockfiles" strategy.

The plumbing is there for **future** divergent rules — when git 3.x changes the lockfile pattern, or when reftable goes from opt-in to default and the storage layout shifts further, the rule lands at the existing API surface. No call-site refactor needed.

## Consequences

### Positive

- **External git agents (terminal, other GUI, CI) are detected**: badge updates within the coalescer's debounce window after any external commit / stash / fetch / etc.
- **Consistency at refresh time**: `gitOperationInFlight` deferral means Sprig never queries `git status` mid-mutation, so badge state never reflects a partial write.
- **Submodule + linked-worktree discovery is recursive**: nested submodules at any depth are watched without a hand-coded recursion at each agent site.
- **Storage-layout-agnostic**: loose refs, packed-refs, reftable all work uniformly — we don't switch on git version for the watch path.
- **Tier 1 portable**: the path math + lockfile rules + submodule/worktree discovery have no platform APIs. macOS / Linux / Windows agents share the same logic.

### Negative

- **More watchers per repo**: each top-level worktree induces watches on the worktree + `.git/` + N submodules + M linked worktrees. For a Chromium-scale super-repo with hundreds of submodules, this is hundreds of FSEvents/inotify subscriptions per agent — within budget but worth tracking.
- **Submodule discovery cost**: `git submodule status --recursive` runs git once per re-scan. For repos with many submodules and a fast-changing `.gitmodules`, this could become a hot path. We don't yet cache discoveries between scans (planned: invalidate on `.gitmodules` change only).
- **Trust-but-verify gap**: this ADR doesn't address the `core.fsmonitor` correctness commitment. If our watcher ever misses a path under `.git/`, the user's `git status` returns wrong results silently. M3 work introduces periodic real-`git status --no-fsmonitor` validation; until then we accept the gap.
- **Concurrency with Sprig's own git invocations is not yet handled**: Sprig spawns its own `git status` to refresh state. While that runs, the watcher might fire events for `.git/` changes our own git just made — leading to a redundant refresh queued behind the in-flight one. Coalescing helps but isn't optimal. M2 agent work introduces a "Sprig is currently running git" suppression flag.

### Deferred to follow-ups

- **Initial-clone detection**: `<repo>/.git/HEAD` exists but `git rev-parse HEAD` fails during clone. M2 agent work skips refresh during this window.
- **`core.fsmonitor` protocol versioning**: when the user's git negotiates a newer fsmonitor protocol than our hook supports, we currently fail the negotiation. M3 introduces version-aware hook negotiation.
- **`core.fsmonitor` trust-but-verify**: M3.
- **Coalescer integration with `gitOperationInFlight`**: this ADR introduces the signal; the agent's coalescer wires it in M2-Mac work.

## Alternatives considered

- **Watch only the worktree, ignore `.git/`** — what the original watcher does. Badges go silently stale after every external commit. UX regression that disqualifies this entirely.
- **Run `git status` on a periodic timer** — wasteful, defeats the FSEvents/inotify perf model, and still races with concurrent ops.
- **Use `core.fsmonitor` from the *consumer* side** — `core.fsmonitor` is git → fsmonitor for "what changed in the worktree." It does not notify about ref/index changes. Wrong tool.
- **Watch only specific files inside `.git/`** (HEAD, index, refs/...) instead of the whole subtree — adds complexity (versioned trigger lists) and per-file FSEvents subscription overhead with no perf win at typical repo sizes. Recursive watch + lockfile filter is the same observable behavior with simpler code.

## References

- ADR 0024 — Sprig is the `core.fsmonitor` source of truth for the user's git (outgoing direction)
- ADR 0021 — performance budget; coalescer + debouncing
- ADR 0047 — git 2.39 minimum supported version
- `docs/architecture/fs-watching.md` — implementation overview
- `packages/GitCore/Sources/GitCore/GitMetadataPaths.swift` — code

## Audit obligation

Adopting this ADR implies an audit of prior work to confirm it doesn't conflict with the multi-agent assumptions made here. See the entry in `docs/planning/risk-register.md` (R15) for the concrete tracking item; the audit lands in a follow-up PR before M2 work begins.
