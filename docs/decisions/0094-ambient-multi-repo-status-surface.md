---
status: proposed
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0094. Ambient multi-repo status surface — resolving the no-tray vs at-a-glance tension

## Context and problem statement

The storage persona's most Dropbox/Egnyte-like expectation is at-a-glance awareness across
*all* their repos ("which ones need attention?") plus a gentle "new commits landed on your
branch." But ADR 0034 (no menu-bar/tray app) and ADR 0014 (notification restraint)
deliberately preclude a persistent surface, and the existing fetch digest / status insights
(ADR 0077) live only inside the on-demand, per-repo Status window (`RepoStatusSummary`
already carries `lastCommitDate` and `fetchDigests`). This ADR exists to make that trade-off
a conscious decision rather than an accident.

**This ADR is intentionally left at `proposed` pending a maintainer choice of surface — the
implementing agent must get that choice ratified before building (see the orchestration
prompt). The options and a recommendation are below.**

## Decision drivers

- Serve the storage persona's cross-repo view.
- Do not reintroduce an always-running tray/menu-bar icon (ADR 0034).
- Do not spam notifications (ADR 0014).

## Considered options

1. **Status-window-only (status quo).** Per-repo, on-demand. Cheapest; arguably insufficient
   for someone managing many synced folders.
2. **A "Repositories" roll-up task window.** On-demand, opened from a Finder right-click on a
   watch root (or a `Sprig ▶` entry), listing every watch-root repo with ahead/behind, dirty
   state, and last-fetch. Respects ADR 0034 (no always-on icon) while giving the cross-repo
   view. Backed by a `MultiRepoStatusViewModel` aggregating `RepoStatusSummary` across roots.
3. **Finder sidebar / tag integration** showing badged repo roots — more ambient, more
   platform-specific surface area.
4. **Narrowly-scoped opt-in notifications.** Per-repo "notify me when my current branch's
   upstream gets new commits," default **off**, piggybacking the existing hourly fetch +
   `SyncOps.fetchAllDigesting` (no new polling, no new daemon).

## Decision (recommended, pending ratification)

**Option 2 + Option 4 (opt-in), explicitly NOT a tray.** The on-demand roll-up window gives
the cross-repo view without violating ADR 0034; the opt-in per-repo notification gives the
"someone pushed to my branch" nudge without violating ADR 0014's restraint (default off,
reuses existing fetch cadence). Option 3 stays on the radar as a later enhancement. If the
maintainer prefers to hold the line at Option 1, this ADR records that instead and closes.

## Consequences

**Positive**
- The storage persona gets a real cross-repo view and an optional ambient nudge, with no tray.

**Negative / trade-offs**
- Aggregating across many roots has a cost; bound it (reuse cached `RepoStatusSummary`, refresh
  on the existing fetch tick) and keep the window on-demand.
- Even opt-in notifications are a step toward "ambient"; the default-off + single-purpose
  scope is what keeps it inside ADR 0014's spirit.

## Links

- Tensions with ADR 0034 (no menu-bar), 0014 (notification restraint). Builds on 0077 (status
  insights / fetch digest), 0068/0064 (fetch cadence), 0030 (Finder-first). Uses
  `RepoStatusSummary`, `SyncOps.fetchAllDigesting`.
