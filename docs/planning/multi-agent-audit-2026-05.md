# Multi-agent git interactions — audit (R15)

Triggered by ADR 0056 (external-git-agent awareness). Reviews every Tier 1 / Tier 2 site that talks to git or interprets repo state and answers: **what happens if a different agent (terminal git, another GUI, CI on the same machine) has mutated `.git/` between two of our reads?**

This audit completes the obligation called out in `risk-register.md` R15.

## Severity scale

- **Critical** — data corruption or wrong results that the user would see.
- **High** — spurious failures or incorrect behavior in common scenarios.
- **Medium** — edge case, low probability, or limited blast radius.
- **Low** — theoretical / informational.

## Scope

Files audited:

| File | Lines | Responsibility |
|---|---|---|
| `packages/GitCore/Sources/GitCore/Runner.swift` | 219 | One-shot git invoker |
| `packages/GitCore/Sources/GitCore/CatFileBatch.swift` | 216 | Long-lived `cat-file --batch` actor |
| `packages/GitCore/Sources/GitCore/RepoDiscovery.swift` | sampled | Repo-tree scanner |
| `packages/RepoState/Sources/RepoState/RepoStateStore.swift` | 118 | In-memory per-repo badge state |
| `packages/WatcherKit/Sources/WatcherKit/PollingFileWatcher.swift` | 175 | Portable polling-based watcher |
| `Benchmarks/SprigCoreBenchmarks/SprigCoreBenchmarks.swift` | 380 | Synthesizers + benchmark suite |

## Findings

### F1 — `GitCore.Runner` has no retry on git-side lock contention (Medium)

**Where:** `Runner.run(_:cwd:stdin:throwOnNonZero:)` lines 62–130.

**What goes wrong:** When Sprig spawns a write-y git operation (`git config`, `git stash`, `git add`) while another agent holds `index.lock` / `packed-refs.lock` / etc., git fails with stderr like `fatal: Unable to create '/path/.git/index.lock': File exists.` This surfaces as `GitError.nonZeroExit`. Callers must implement their own retry, which today none do.

**Status of read-only ops:** `git status` is read-only; it'll briefly read-lock the index, succeed, release. No contention with concurrent writes. Reads are fine.

**Recommended fix:** Add an opt-in `retryOnLockContention: RetryPolicy = .none` parameter. `RetryPolicy.exponential(maxAttempts: 3)` matches typical lockfile lifetime (<100 ms). Detect by stderr pattern match against `Unable to create '*.lock': File exists`. **Deferred** — applied when the agent's first write op surfaces a real failure case.

**Today's mitigation:** Doc-comment update calling out the issue.

### F2 — `GitCore.CatFileBatch` holds open packfiles across `git gc` (High)

**Where:** `CatFileBatch` actor — long-lived `git cat-file --batch` process, lines 23–123.

**What goes wrong:** `git cat-file --batch` mmaps pack files when it first reads pack-resident objects. When `git gc` rewrites/removes those packs (in the same repo, by either Sprig or an external agent), our process keeps the stale mappings. Subsequent `read()` calls may:
- Return wrong bytes (mmap'd region of a now-orphaned pack)
- Fail with "object not found" (the object got moved to a different pack)
- Race with the rewrite and silently corrupt content

This is a **documented git limitation**. The recommended pattern is to restart `cat-file --batch` after a known repacking event.

**Recommended fix (multi-step):**

1. **(this PR)** Add a doc-comment warning so callers know they need to handle this.
2. **(follow-up)** Add `CatFileBatch.restart() async` (close + re-init internally). Idempotent and safe to call from any actor context.
3. **(M2 agent work)** Wire watcher events on `objects/pack/` to trigger a restart on every CatFileBatch instance for that repo.

**Today's mitigation:** Doc-comment update + audit entry.

### F3 — `RepoStateStore` has no out-of-order-apply guard (Medium)

**Where:** `RepoStateStore.apply(_:)` lines 64–75.

**What goes wrong:** `apply()` is whole-snapshot replace. Two `apply()` calls landing out of order — say, an in-flight `git status` from t=0 finishes after an in-flight `git status` from t=10 — means the t=10 result is overwritten by stale t=0 data. The store's actor isolation serializes the calls, but doesn't reject older inputs.

**Real-world likelihood:** This requires the agent to dispatch multiple concurrent `git status` calls AND have them complete out of order. The agent's coalescer should serialize them today (one in-flight at a time), so this is mostly theoretical.

**Recommended fix (two paths):**

- **(today)** Doc-comment that callers MUST serialize `apply()` calls — the store doesn't enforce ordering.
- **(follow-up)** Add a monotonic `applySequence` parameter. Store keeps the highest seen and rejects (or no-ops) older. Belt-and-suspenders against agent bugs.

**Today's mitigation:** Doc-comment update.

### F4 — `RepoStateStore.badge(for:)` doesn't case-fold paths (Low)

**Where:** `badge(for path: URL)` line 86.

**What goes wrong:** macOS HFS+ and Windows NTFS are case-insensitive by default. Git stores paths case-sensitively. If porcelain output reports `Foo.swift` but the shell extension queries for `foo.swift`, our trie lookup misses.

**Real-world likelihood:** Low — the shell extension passes the path it got from the OS, and most macOS filesystems return the on-disk casing consistently. But edge cases (a user renaming `Foo.swift` → `foo.swift` via a case-insensitive checkout) can produce mismatches.

**Recommended fix (deferred):** Per-platform path normalization at the trie boundary. Tracked as part of the M2 agent work; this isn't a single-line fix because the agent decides which volumes are case-insensitive.

**Today's mitigation:** Doc-comment + audit entry.

### F5 — `WatcherKit.PollingFileWatcher` skips `.git/` via `.skipsHiddenFiles` (High)

**Where:** `walk(_:into:)` lines 90–109 — passes `[.skipsHiddenFiles]` to `contentsOfDirectory`.

**What goes wrong:** ADR 0056 requires Sprig to watch `.git/` (in addition to the worktree) so that external commits / fetches / etc. trigger badge refreshes. The polling watcher's hidden-file filter excludes `.git/` from a worktree walk. If the agent passes `[worktree]` as the watch root and expects `.git/` events, none arrive.

**Real-world likelihood:** Will hit on day 1 of M2 agent work if the agent doesn't know to pass `.git/` as a separate root.

**Recommended fix:** Document the expected usage pattern: **the agent MUST pass each of (worktree, gitDir, every submodule's gitDir, every linked worktree's gitDir) as a separate root in `paths`.** The watcher's filter is correct in isolation; the agent layer is responsible for enumerating the roots.

**Today's mitigation:** Doc-comment update on `start(paths:)` + this audit entry. A more aggressive fix (special-case `.git` as not-hidden) is rejected — it'd surprise callers using the watcher for non-git purposes.

### F6 — Benchmark synthesizers (No findings)

**Where:** `synthesizeRepo(fileCount:)`, `synthesizeTree(fileCount:dirsPerLevel:)`.

**Analysis:** Single-writer by design. The synthesizer runs to completion before any timed loop starts. No external agent should touch a synthesized repo during a benchmark. No multi-agent risks.

### F7 — `RepoDiscovery` snapshot consistency (Low)

**Where:** `RepoDiscovery.scan(root:options:)`.

**What goes wrong:** Repos may be created/deleted during a scan. Each scan returns a point-in-time snapshot; new repos created mid-scan may or may not be reported depending on traversal order. Low impact since callers are expected to re-scan periodically.

**Today's mitigation:** Existing behavior is correct. No change.

## Summary

| Finding | Severity | Action this PR | Action deferred |
|---|---|---|---|
| F1 — Runner no lock-retry | Medium | Doc-comment | `retryOnLockContention` param |
| F2 — CatFileBatch pack-mmap | High | Doc-comment | `restart()` method + watcher wire-up |
| F3 — RepoStateStore out-of-order apply | Medium | Doc-comment | `applySequence` guard |
| F4 — RepoStateStore case-insensitive lookup | Low | Doc-comment | Per-platform normalization |
| F5 — PollingFileWatcher skips `.git/` | High | Doc-comment | (none — by design) |
| F6 — Benchmark synthesizers | — | — | — |
| F7 — RepoDiscovery snapshot races | Low | — | — |

**No critical findings.** Two High-severity items (F2, F5) are resolved by documentation in this PR — the first because the fix needs the watcher wired in (M2 agent work), the second because the "fix" is to use the watcher correctly (no code change needed).

The Medium-severity items (F1, F3) get follow-up tickets when the agent code lands and surfaces concrete failure cases. Speculative fixes today would add complexity without proven need.

## Follow-up checklist (post-M2-agent landing)

- [ ] Add `Runner.run(retryOnLockContention:)` parameter once a write-op-from-Sprig surfaces a real lock-contention failure in CI or user reports.
- [ ] Add `CatFileBatch.restart()` and wire to watcher events on `objects/pack/`. Required for correctness once we read pack-resident objects regularly (diff viewer, log graph rendering).
- [ ] Add `RepoStateStore.apply(_:sequence:)` overload with monotonic guard. Optional; today's actor serialization is sufficient if the agent enqueues correctly.
- [ ] Per-platform case-folding helper used at the `RepoStateStore.badge(for:)` boundary.

These tasks land in M2 agent PRs as the relevant code is built.
