---
status: accepted
date: 2026-06-19
deciders: maintainer
consulted: —
informed: —
---

# 0096. Submodules tracked by default — auto-reconcile (no force) + throttled suggestion

## Context and problem statement

ADR 0031 gave submodules badges, a right-click menu, and a future `SubmoduleManager`
window, but left the *behavior* policy open: when does Sprig actually run `git submodule
update`? Git's defaults make submodules opt-in at almost every turn — a fresh clone leaves
them empty, a branch switch doesn't touch them, a fast-forward doesn't move them — so the
overwhelmingly common failure mode for non-experts is "I checked out the branch, why is my
submodule pointing at the wrong commit / empty?" The submodule pointer is committed history;
leaving it stale is a silent correctness hazard, not a preference.

The settled policy is **submodules are tracked by default**: Sprig keeps the working
submodule reconciled with the super-repo's recorded pointer unless the user has been editing
the submodule, in which case it must NEVER clobber that work. We also want to *notice* when a
submodule is behind (either the super-repo moved its pointer, or the submodule's own upstream
gained commits) and *offer* an update — but not nag on every status refresh.

## Decision drivers

- **Tracked by default, but never destructive.** Reconcile silently when it's safe; a
  submodule with local changes is the user's work and is left exactly as-is.
- **Git's own `submodule update` is all-or-nothing on dirt.** Verified against git 2.43: when
  a checkout would overwrite local *tracked* changes in any submodule, git ABORTS THE WHOLE
  COMMAND (exit 1) and updates nothing — even the clean submodules. A naive
  `update --init --recursive` is therefore unusable as the default op the moment one submodule
  is dirty.
- **Recoverability over refusal.** When the user *does* want to discard local submodule work
  to reconcile, that must be a one-tap, fully-reversible action (ADR 0033 / 0075 discipline),
  not a manual `git -C sub reset --hard`.
- **Suggest, don't nag.** The "you're behind" heuristic can be true on every refresh; throttle
  it per repo.

## Considered options

1. **Pre-classify, update clean ones, skip + report dirty, offer snapshot-then-force** (this
   ADR). Read `git submodule status`, probe each submodule for dirt, run
   `update --init --recursive` over only the clean paths, report the dirty ones, and offer an
   explicit per-submodule "snapshot then force" remedy.
2. **Run `update --init --recursive` and surface git's abort.** Rejected: one dirty submodule
   blocks reconciling all the others, and the error is a raw git abort, not an actionable
   "these N are dirty, here's what to do."
3. **Always `update --force`.** Rejected outright: silently destroys uncommitted submodule
   work — the exact thing "never destructive" forbids.

## Decision

**Add `SubmoduleKit.SubmoduleUpdate` (the auto-reconcile op), `SubmoduleKit
.SubmoduleFreshnessProbe` (the out-of-date / upstream-newer detection), and `SubmoduleKit
.SubmoduleSuggestionThrottle` (the per-repo throttle store), all over `GitCore.Runner` and
`SafetyKit.WorktreeBackup`.** Submodule tracking is on by default via a new preference
`submoduleAutoUpdateEnabled` (default `true`).

**Auto-reconcile (`SubmoduleUpdate.reconcile`).** Reads `git submodule status`, probes each
submodule's worktree for dirt (`git -C <sub> status --porcelain -z` — ANY output, tracked or
untracked, counts as dirty), then runs `git submodule update --init --recursive -- <clean
paths…>` over ONLY the clean submodules. Dirty submodules are **skipped and reported** in the
outcome (`skippedDirty`), never touched. A super-repo with no submodules is a no-op.

The conservative dirty test treats *any* working-tree change as "skip", including
untracked-only dirt that git's checkout would actually tolerate. That's deliberate: a force
later would discard untracked work too, so the simplest safe rule is "if there's anything
there, don't auto-touch it."

**Snapshot-then-force remedy (`SubmoduleUpdate.snapshotThenForce`).** For one dirty submodule
the user explicitly elects to overwrite: take a `SafetyKit.WorktreeBackup` snapshot **inside
the submodule's own repo** (ADR 0075 — a `refs/sprig/backup/<ts>/<branch>` ref in the
submodule's gitdir capturing tracked + untracked work via a throwaway index) and ONLY THEN
run `git submodule update --init --force -- <sub>` from the super-repo. The discarded work is
restorable from the submodule's Recover surface. No super-repo HEAD moves, so **no ADR 0033
snapshot ref or `DestructiveOpTier` entry is minted** here — the recoverable state is the
submodule's uncommitted working tree (a `WorktreeBackup`), exactly as ADR 0089's sparse-
checkout force path establishes for working-tree-only destruction.

**Throttled suggestion (`SubmoduleFreshnessProbe` + `SubmoduleSuggestionThrottle`).** The
freshness probe surfaces two read-only signals per submodule:

- **out-of-date** — the checkout differs from the super-repo's recorded pointer (the `+` state
  of `git submodule status`, read with no extra spawn);
- **upstream-newer** — the submodule's remote has commits its checkout lacks
  (`git rev-list --count HEAD..<upstream>` inside the submodule, where `<upstream>` is `@{u}`
  on a branch else `origin/HEAD` for the detached-HEAD checkout `submodule update` produces).

`shouldSuggestUpdate` is the OR of the two. When it fires, the throttle gates how often the
suggestion is *shown* per repo via a new preference `submoduleSuggestionThrottleHours`
(default 4). State is a single integer-epoch-seconds timestamp in
`<git-common-dir>/sprig/submodule-suggestion-shown`, with the common dir resolved by
`git rev-parse --path-format=absolute --git-common-dir` so all linked worktrees share one
throttle file. A missing/unparseable file means "never shown" → not throttled.

## Consequences

**Positive**

- Submodules "just work" for the common case (clean → reconciled to the recorded pointer)
  without the user knowing what a submodule is.
- A submodule the user is editing is never silently clobbered; the only path that overwrites
  it is explicit and fully reversible.
- The "you're behind" nudge is real-signal-driven (super-repo drift OR upstream-newer) and
  rate-limited per repo.

**Negative / trade-offs**

- The conservative dirty rule skips untracked-only submodules that git's plain `update` would
  have safely checked out. The cost is a stray "skipped: sub" report and a one-tap force; the
  benefit is a single safe rule with no "but untracked is fine, tracked isn't" footgun.
- `SubmoduleKit` gains a `SafetyKit` dependency (Tier-1 → Tier-1, no platform coupling) for
  the in-submodule backup.
- `commitsBehindUpstream` reflects whatever remote-tracking refs are already local — the probe
  never fetches. Callers wanting fresh upstream data fetch first (the ADR 0068 background
  auto-fetch keeps those warm).

## Implementation status (2026-06-19)

**Shipped this slice (SubmoduleKit + GitCore + prefs schema):**

- `SubmoduleKit.SubmoduleUpdate` — `reconcile(at:runner:)` (dirty-skip + report) and
  `snapshotThenForce(submodulePath:in:runner:)` (in-submodule `WorktreeBackup` then
  `update --init --force`).
- `SubmoduleKit.SubmoduleFreshnessProbe` / `SubmoduleFreshness` — out-of-date + upstream-newer
  detection and the `shouldSuggestUpdate` heuristic.
- `SubmoduleKit.SubmoduleSuggestionThrottle` — the per-repo last-shown store under
  `<git-common-dir>/sprig/`.
- New `AppPreferences` fields, all additive (old prefs files decode with the defaults):
  `submoduleAutoUpdateEnabled` (default `true`), `submoduleSuggestionThrottleHours`
  (default `4`), and `fetchRecurseSubmodules` (default `true`, reserved for the follow-up
  below).
- Real-git tests in `SubmoduleKitTests` (clean update, dirty-skip-not-clobbered, snapshot-
  then-force backup + byte-exact restore round-trip, out-of-date vs upstream-newer, throttle
  fires → suppresses → fires-again).

**Deferred follow-up (NOT in this slice — view-model / scheduler wiring):**

- Wire `--recurse-submodules` into the fetch flows and run a post-fast-forward
  `SubmoduleUpdate.reconcile` from `BranchSwitcherViewModel`, `SyncViewModel`, and
  `AgentKit.AutoSyncScheduler`, gated on `submoduleAutoUpdateEnabled` /
  `fetchRecurseSubmodules`. The `fetchRecurseSubmodules` preference is defined now so the
  prefs schema is stable when that lands.
- Surface the throttled suggestion + the skipped-dirty report + the snapshot-then-force button
  in the `SubmoduleManager` task window (ADR 0031) and a `sprigctl submodule` CLI face.

## Links

- Amends **ADR 0031** (submodule badges / right-click / SubmoduleManager) with the tracked-by-
  default behavior policy and the reconcile/force engine that surface will drive.
- Builds on **ADR 0075** (`WorktreeBackup` — the in-submodule force path's recovery substrate)
  and **ADR 0033** (destructive-op safety; the force here is working-tree-only, so no HEAD
  snapshot ref is minted — same reasoning as ADR 0089's sparse-checkout force path).
- Relates to **ADR 0068** (background auto-fetch keeps the remote-tracking refs the upstream-
  newer signal reads warm) and **ADR 0071** (the Sync verb the follow-up wires the post-ff
  reconcile into).
- Mirrors **ADR 0089**'s dirty-skip + snapshot-then-force pattern (selective sync), applied to
  submodules instead of sparse-checkout folders.
