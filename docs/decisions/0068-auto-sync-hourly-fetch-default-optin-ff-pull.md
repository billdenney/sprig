---
status: accepted
date: 2026-06-09
deciders: maintainer (directive), engineering
consulted: —
informed: —
---

# 0068. Auto-sync — hourly fetch-all default, opt-in fast-forward auto-pull

## Context and problem statement

Maintainer directive (2026-06-09), verbatim intent: *"Default to periodic fetch from all sources (perhaps hourly). Add an option to also have a default pull so that the local branches are kept up to date and the local directory is also kept up to date."* The directive is part of a broader push to make Sprig more useful to people less familiar with git, with less reliance on AI features (see `docs/research/git-beginner-affordances.md` for the companion idea backlog).

ADR 0064 already ratified auto-fetch with an adaptive 5/15/30-minute cadence ladder driven by power/network/focus signals. Two problems have emerged with that as the *default*:

1. **The ladder's value is back-loaded.** The adaptive signals (AC vs battery, metered, focus) require Tier-2 platform adapters on every OS before *any* auto-fetch ships. An hourly timer needs none of them — it can ship in the portable engine today and start delivering the core benefit (badges and behind-counts that are roughly current).
2. **For the target user, predictability beats adaptivity.** A user who doesn't think in git terms benefits from "Sprig checks for updates about once an hour" as a one-sentence mental model. "Sprig fetches every 5–30 minutes depending on power, network cost, and focus" is a paragraph.

Separately, fetch alone leaves a gap for beginners: their *local* branches and working directory still drift behind until they explicitly pull — and "pull" is exactly the kind of operation less-experienced users defer until it becomes a conflict-laden event. An automatic, **provably-safe** pull keeps them current without ceremony.

## Decision

### 1. Default cadence: hourly `git fetch --all --prune`, per registered repo

- The engine's default auto-fetch interval is **60 minutes** with ±10 % jitter (so a fleet of repos doesn't fetch in lockstep), firing once shortly after agent start.
- ADR 0064's adaptive 5/15/30-minute ladder is **demoted from default to an opt-in override** ("Frequent (adaptive)") selectable per repo in the Status task window once the platform signal adapters exist. 0064's pause conditions (battery <50 %, Low Power Mode, lid closed, display asleep) and its unreachable-remote exponential backoff are **retained** — they layer on top of whatever cadence is selected, via the `SyncPolicy` seam below.
- Fetch is `git fetch --all --prune --no-write-fetch-head --quiet`, honoring the user's remotes, credentials, and config (defer-to-git, ADR 0023). `--prune` keeps remote-tracking refs honest; `--no-write-fetch-head` avoids churning `FETCH_HEAD` (and waking `.git`-watchers) on a background operation.

### 2. Opt-in auto-pull: fast-forward only, fail-closed everywhere

When the user enables auto-pull (off by default), after each successful background fetch the engine fast-forwards **every local branch that can be fast-forwarded provably without loss**, and updates the working directory for the checked-out branch:

| Branch state | Action |
|---|---|
| Behind upstream, not ahead, **not** the checked-out branch | `git fetch . <upstream-ref>:<branch>` (ref-only fast-forward; git itself refuses non-FF and branches checked out in any worktree) |
| Behind upstream, not ahead, checked-out, **clean** worktree | `git merge --ff-only <upstream-ref>` (updates working directory) |
| Behind upstream, not ahead, checked-out, **dirty** worktree | Skip, report `skippedDirtyWorktree` (an `autostash` option exists for the adventurous; default off) |
| Ahead only / diverged / no upstream / upstream gone / mid-merge or -rebase | Skip with a typed, per-branch reason — never merge, never rebase, never touch the user's work |

Rationale for fail-closed: auto-pull runs unattended. The only operations it may perform are ones git guarantees are lossless (fast-forwards). Anything requiring judgment (diverged history, dirty tree, conflicts) is *reported*, not resolved — those surface in the Status task window / `sprigctl sync` output as "needs your attention," which is itself valuable signal for a beginner.

Mid-operation guard: if `GitMetadataPaths.gitOperationInFlight` reports a merge/rebase/cherry-pick/am in progress (ADR 0056 awareness), the whole auto-pull pass for that repo is skipped.

### 3. Engine surface (this ADR's implementation slice)

- **`GitCore.SyncOps`** — `fetchAll(prune:)`, `branchSyncStates()` (parses `for-each-ref` with `%(upstream)`/`%(upstream:track)`), `fastForwardLocalBranches(options:)` returning per-branch typed outcomes.
- **`PlatformKit.SyncPolicy`** — the seam ADR 0064's platform signals plug into: `decision() -> .allow | .pause(reason:)`. Portable default `AlwaysAllowSyncPolicy`; Mac/Windows power-aware adapters are the M2/M2-Win slice.
- **`AgentKit.AutoSyncScheduler`** — actor; interval + jitter loop, overlap-skip, `SyncPolicy` gate per tick, injectable sleep for tests, `fireNow()` for the Status window's "Fetch now" button.
- **`RepoAgent` wiring** — optional `AutoSyncConfiguration` (disabled by default) starts a scheduler per agent whose job is `fetchAll` + (if enabled) `fastForwardLocalBranches`.
- **`sprigctl sync`** — one-shot CLI: fetch + report (+ `--pull` to fast-forward, `--json` for tooling). Gives the feature a scriptable, testable surface and a manual "sync now" for CLI users.
- **Preferences** — `autoFetchEnabled` (default **true**), `autoFetchIntervalMinutes` (default **60**), `autoPullFastForward` (default **false**). Decoding tolerates their absence so existing preference files load unchanged.

## Considered options

1. **Hourly default + opt-in FF-pull** (this ADR).
2. Keep 0064's adaptive ladder as the default — blocked on platform adapters; harder to explain; the original complaint (battery) is equally solved by "hourly" being rare.
3. Auto-pull with `--rebase` for diverged branches — rewrites local commits unattended; violates the fail-closed principle and ADR 0033's spirit. Rejected.
4. Auto-pull default-on — tempting for the beginner story, but a background process mutating the working directory surprises *expert* users; off-by-default with a one-click enable in onboarding (ADR 0039 adaptive onboarding can offer it to beginner-profile users) is the right polarity.
5. `git maintenance`'s built-in hourly `prefetch` task (ADR 0026 already enables it where supported) — prefetches into `refs/prefetch/*` only; doesn't update remote-tracking refs, so badges/behind-counts stay stale, and there's no pull story. Complementary plumbing, not a substitute.

## Consequences

**Positive** — auto-fetch ships in the portable engine now (no platform-adapter dependency); one-sentence mental model; behind-badges become trustworthy; beginners on auto-pull stop accumulating drift; every skip reason is surfaced rather than swallowed.

**Negative / trade-offs** — hourly is less fresh than 0064's focused-5-min default (mitigated by per-repo override + "Fetch now"); background fetch can contend with user-initiated git on slow filesystems (mitigated: fetch is read-mostly, and the in-flight-operation guard defers); auto-pull moving the working tree underneath a running build/editor can surprise — documented in Preferences copy, off by default, and skipped when the tree is dirty.

## Amendment — host wiring (2026-06-11)

The M2 agent-host substrate: **`AgentKit.AgentPreferencesWiring`** is the one mapping from
`AppPreferences` to this ADR's `AutoSyncStartup` (and ADR 0075's `AutoBackupStartup`) — every
host calls it instead of re-deriving intervals/TTLs from raw preference fields, so a
preferences file means the same thing under every host. First consumer: **`sprigctl agent
--preferences PATH`** — opt-in per invocation (omitted = the watch-only diagnostic behavior;
the platform hosts always pass their preferences path). A missing file means a
not-yet-written store and uses the documented defaults; a malformed file is an error, not a
silent reset. Knobs the preferences don't express keep this ADR's defaults: fetch fires once
at host start, backup does not. End-to-end pinned by a CLI test proving the fire-on-start
fetch advances the remote-tracking ref within the run window.

## Links

- Supersedes the *default-cadence* portion of ADR 0064 (amended in place; signals/backoff/Status-window surfaces unchanged).
- ADR 0023 (defer to git), 0026 (maintenance/prefetch), 0033 (safety tiers — auto-pull performs only non-destructive FFs so no snapshot is required), 0039 (onboarding can offer auto-pull), 0056 (in-flight-operation deferral), 0063 (forge badges depend on fetch recency).
- Companion idea backlog: `docs/research/git-beginner-affordances.md`.
