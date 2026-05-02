---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0066. Stale `index.lock` recovery flow (60s threshold + one-click clear)

## Context and problem statement

A stale `.git/index.lock` (or `HEAD.lock`, `packed-refs.lock`, `config.lock`) left by a killed external `git` process makes every git operation fail with `Another git process seems to be running…` until the lock file is removed. SourceTree ticket SRCTREEWIN-1130 has been open 8+ years; Tower, Fork, and GitHub Desktop all hit the same class of bug. Users without CLI fluency can't recover. Users with CLI fluency learn to `rm .git/index.lock` and move on, but the experience is jarring.

ADR 0056 already gives Sprig the ability to *detect* the in-flight state during refresh — `GitMetadataPaths.gitOperationInFlight(in:gitVersion:)` returns true when any of the canonical lock files exist. `RepoRefreshDriver` (per the May-2 work) tracks `firstDeferralAt: Date?` so the agent's main loop can compute "how long has this repo been stuck?"

What's missing is the **user-facing recovery path**: when the lock has persisted long enough that it's almost certainly stale (no live git process owns it), Sprig should surface a clear, one-click recovery affordance.

## Decision drivers

- Stale-lock recovery is the most common "I have to use the CLI to fix Sprig" experience in competing clients.
- Detection must avoid false positives: a `git rebase -i` paused for user input also leaves `index.lock` in place; we don't want to trample it.
- Recovery should be *user-confirmed*, not silent — if Sprig is wrong about staleness, only the user can know.
- Preserve Finder/Explorer-first invariant — the recovery surface is a tiny task window opened on demand from a Notification Center alert.

## Considered options

1. **Notification Center alert + tiny confirmation task window after 60s** (this ADR).
2. Auto-clear after 5 min if no PID owns it. More aggressive; users get unblocked faster but lose explicit confirmation. Risk: clobbering a paused interactive rebase.
3. Just keep deferring refreshes — no user-facing action. Matches what other clients do; user remains stuck.
4. Surface in Sprig Status task window only — no Notification Center. Less interrupt-y; easier to miss.

## Decision

**Option 1.** Two-stage flow: passive deferral first (the ADR 0056 / `RepoRefreshDriver` behavior), active surfacing after 60 seconds.

### Detection

- The agent's main loop monitors every watched repo's `RepoRefreshDriver.firstDeferralAt` on each tick.
- When `Date().timeIntervalSince(firstDeferralAt) > 60`, the repo enters "stale-lock candidate" state.
- The agent re-runs `GitMetadataPaths.gitOperationInFlight(in:)` to confirm the lock is still present (avoids false alarms on transient blips).
- Additionally, the agent attempts to identify the lock file's owning PID:
  - **macOS** / **Linux**: `lsof -t -- <lock-path>` or read `/proc/locks` — if any live process holds it, recovery is *not* offered.
  - **Windows**: query the file's exclusive-handle holders via `NtQuerySystemInformation(SystemHandleInformation)` — if any live process holds the handle, recovery is *not* offered.
- If no live process owns the lock, the recovery flow proceeds.

### Surface (1) — Notification Center alert

> **A git operation appears stuck on `<repo-name>`**
> The repo has been waiting for `<lock-file>` (held since <when>) for over a minute. Review and clear?
> [ Review… ] [ Dismiss ]

The alert is rate-limited per repo: at most one per 30-minute window. The "Dismiss" button suppresses for 30 minutes; "Review…" opens the surface (2).

### Surface (2) — tiny confirmation task window

> **Stale lock on `<repo-name>`**
>
> Lock file: `<gitDir>/<lock-file>`
> mtime: `<wall-clock>` (`<elapsed>` ago)
> Owning process: none (lock appears stale)
>
> Clearing this lock removes the file and lets Sprig continue. Choose only if you've confirmed no other git tool is running against this repo.
>
> [ Cancel ] [ Show in Finder/Explorer ] [ Clear lock ]

`Clear lock` removes the lock file (`unlink`), then issues a `RepoRefreshDriver.forceRefresh()` to retry. Result is logged via `DiagKit` for diagnostic bundles.

`Show in Finder/Explorer` opens the `.git/` directory with the lock file selected — useful for users who want to inspect first.

### Driver changes

`RepoRefreshDriver` already exposes `firstDeferralAt` (this is the forward-compat enabler shipped 2026-05-02 on `feat/repostate-driver-deferral-timestamp`). No further driver changes needed.

The agent's main loop (M2 work, not yet built) consumes `firstDeferralAt` along with the repo's gitDir to compute the 60s elapsed-time check.

### What the recovery does NOT do

- It does **not** kill any process — recovery only proceeds if PID detection finds none.
- It does **not** clear `index.lock` if the user is mid-`git rebase -i` (Sprig detects the rebase-in-progress state via `<gitDir>/rebase-merge/` or `<gitDir>/rebase-apply/` directory existence and refuses to clear).
- It does **not** auto-recover; the user always confirms via the task window.

## Consequences

**Positive**
- Closes the SourceTree-SRCTREEWIN-1130 8-year-old class of bug for Sprig users.
- Users without CLI fluency can recover.
- The recovery is conservative: PID check + rebase-in-progress check + user confirmation make false-positive trampling extremely unlikely.
- Pairs with ADR 0033 amendment — the Recover task window can also list "stale-lock recoveries from the last 30 days" for diagnostic purposes.

**Negative / trade-offs**
- 60-second threshold may surprise users running legitimately slow git operations (a `git fetch` on a slow connection over a large pack-file). Mitigation: the PID check + the "Show in Finder/Explorer" inspection step. If users complain, the threshold could be configurable; default of 60 seconds is per the ratification.
- Notification Center alerts in macOS Focus / Do Not Disturb mode may not appear; surface state additionally in the Status task window for users who don't see the alert.
- The PID-detection code is platform-specific and adds Tier-2 platform-adapter surface.
- A misuse: a user clears the lock during a paused interactive rebase that *was* still active. Mitigation: the rebase-in-progress check.

## Links

- Master plan §13.3-K, §13.5.
- Related ADRs: 0033 (destructive-op safety — same recovery surface), 0033 amendment (Recover task window), 0056 (external-git-agent awareness — defines `gitOperationInFlight`), 0030 (Finder-first), 0034 (Notification Center as the system-level alert channel).
- SourceTree SRCTREEWIN-1130: <https://jira.atlassian.com/browse/SRCTREEWIN-1130>
- Related implementation: `firstDeferralAt` diagnostic in `feat/repostate-driver-deferral-timestamp`.
