---
status: accepted
date: 2026-06-10
deciders: maintainer (beginner-affordances directive 2026-06-09), engineering
consulted: —
informed: —
---

# 0071. Sync verb — fetch → fast-forward → plain push, never forced

## Context and problem statement

Affordances item 1.4: TortoiseGit's most-loved button is "Sync" — one verb whose promise a
beginner can hold in one sentence: **make my copy and the server match**. ADR 0068 built the
fetch + fast-forward machinery; the missing half is the push, which is also where the risk
lives: a push verb that escalates to `--force` when rejected would be the most dangerous
button in the product.

## Decision

**The Sync verb is `fetch --all --prune` → ADR 0068 fast-forward pass → plain push of the
current branch.** Composite, with each leg's outcome reported individually.

Push-half rules (`SyncOps.pushCurrentBranch`):

| Situation | Behavior |
|---|---|
| Current branch ahead of upstream | `git push` (plain). Outcome carries the commit count. |
| In sync (`ahead == 0`) | `nothingToPush` — no spawn beyond the state read. |
| No upstream configured, remote(s) exist | `git push -u <remote> <branch>` — publish + track (prefers `origin`, falls back to the first remote). |
| Push rejected (remote moved on) | **`rejectedNonFastForward` — a typed report, never a force.** The remedy is fetch + resolve; the UI routes there. |
| No remotes / detached HEAD | Typed reports; nothing attempted. |

Orchestration (`TaskWindowKit.SyncViewModel`):

- Stages surface as `fetching → fastForwarding → pushing → finished` so the UI can show what
  Sync is doing.
- **Fetch failure is the only `.failure`** (offline/auth — nothing else can run). Diverged
  branches, dirty-tree FF skips, and push rejections are *data* in the terminal `SyncReport`
  — a Sync that found work needing the user is a successful Sync.
- The ADR 0056 guard skips both mutating legs when the repo is mid-operation; fetch still
  runs (read-only).
- `--autostash` is available as an option for the FF leg (default off; the UI offers the
  ADR 0069 set-aside flow explicitly instead).

**Guard hardening shipped with this ADR:** the 0068/0056 "mid-operation" check used
`gitOperationInFlight` (transient *lock files* — another process actively writing), which
misses a **parked** conflicted merge/rebase (markers like `MERGE_HEAD` persist for hours with
no locks). New `GitMetadataPaths.repoIsMidOperation(gitDir:)` combines both signals; the
auto-sync agent job, `sprigctl sync`, and this verb all use it now.

`sprigctl sync` gains `--push` for CLI parity (same outcomes, stable JSON tags).

## Considered options

1. **Plain-push composite with typed rejection** (this ADR).
2. Rebase-on-diverge inside Sync (à la `pull --rebase` + push) — rewrites local commits as a
   side effect of a "make things match" button; beginners can't predict it, and mid-rebase
   conflicts strand them worse than a "needs your attention" report. Remains a power-user
   verb (master plan's "Pull & Rebase").
3. Force-with-lease on rejection — even leased force is history rewriting; ADR 0052 keeps
   that behind the explicit high-tier Force Push verb (typed-phrase confirm, ADR 0033).
4. Push all branches (`push --all`) — publishes work the user may consider private; the verb
   pushes only where the user is standing.

## Consequences

- The 1.x tier of the beginner-affordances backlog is now fully engine-shipped (1.1/1.2
  auto-sync, 1.3 set-aside, 1.4 Sync, 1.5 snapshots pre-existing).
- Shells render the per-leg report lines ("pulled 2 from origin/main", "pushed 1",
  "needs attention: diverged") — M2/M3 shell work.
- A rejected push leaves the user one tap from the resolution flow rather than silently
  failing or dangerously succeeding.

## Links

- Implements `docs/research/git-beginner-affordances.md` item 1.4.
- ADR 0033 (tiering), 0049 (`push.autoSetupRemote` in the defaults bundle — the `-u` publish
  path covers repos that predate it), 0052 (force-push stays a separate verb), 0056
  (mid-operation guard), 0068 (fetch/FF machinery), 0069 (set-aside as the dirty-tree
  companion).
