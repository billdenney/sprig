---
status: accepted
date: 2026-06-10
deciders: maintainer (beginner-affordances directive 2026-06-09), engineering
consulted: —
informed: —
---

# 0069. "Set aside changes" — auto-stash around branch switch

## Context and problem statement

The #1 wall a git beginner hits is `error: Your local changes to the following files would be
overwritten by checkout` — a refusal whose remedy (stash → switch → pop) requires knowing three
commands and their failure modes. Item 1.3 of `docs/research/git-beginner-affordances.md`
(ratified by the 2026-06-09 maintainer directive to make Sprig easier for people less familiar
with git, without AI) proposes Sprig absorb that ceremony into one affordance.

TortoiseGit's equivalent ("Stash & reapply" on switch) is among its most-used conveniences.
Sprig's BranchSwitcher view model (M3) deliberately punted: the MVP rejected the switch with a
hint. This ADR closes that gap.

## Decision

**The Switch Branch verb gains a "Set aside changes and switch" path**, offered exactly when a
plain switch fails with git's dirty-tree refusal:

1. `git stash push --include-untracked -m "Sprig: set aside before switching to <branch>"`
   — untracked files included by default: the affordance promises a clean switch, and a
   beginner's in-progress work is frequently untracked.
2. `git switch <branch>`.
3. `git stash pop`.

**Fail-closed at every step:**

| Step outcome | Behavior |
|---|---|
| Nothing to stash | Degrades to a plain switch; no stash entry created. |
| Stash created, switch fails | Stash popped back on the original branch (best effort) — the tree is exactly as before; the switch error surfaces. |
| Switch succeeds, pop applies | Changes travel with the user; entry dropped. Outcome `reapplied`. |
| Switch succeeds, pop conflicts | git keeps the entry (verified by `StashOps`, not assumed); the switch reports **success** plus outcome `keptInStash` — the UI shows "your changes are saved in the stash; re-apply when ready", never a silent success. |

**Engine surface:** `GitCore.StashOps` (`push(message:includeUntracked:)` / `pop()` with
plumbing-based outcome detection — `refs/stash` before/after, never message parsing) and
`BranchSwitcherViewModel.switchBranch(settingAsideChanges:)` plus the `canOfferSetAside` flag
(set by the dirty-tree refusal) and `setAsideOutcome` side-channel.

**Vocabulary:** the user-facing verb is **"Set aside changes"**, with "(git: stash)" shown per
the progressive-disclosure register (affordances item 2.1) so users graduate into the term.

**Safety analysis (ADR 0033):** no snapshot ref is taken — the stash entry *is* the safety
copy, and every path either re-applies it or verifiably keeps it. ADR 0065's stash-export
protection covers these entries like any other stash. The operation never rewrites history and
never drops a conflicted entry, so it sits below `DestructiveOpTier.low`.

## Considered options

1. **Composite stash/switch/pop with fail-closed restore** (this ADR).
2. `git switch --merge` (three-way-merges local changes into the target) — produces in-tree
   conflict markers *during the switch* with no saved copy of the original state; a beginner
   mid-switch-conflict is worse off than before. Rejected as the default; power users retain it
   via the Commands panel (ADR 0057).
3. Auto-commit to a temp branch instead of stashing — pollutes reflog/history surfaces and
   needs bespoke recovery UX; stash already has list/apply tooling and the ADR 0065 export net.
4. Always auto-stash without asking — mutates state the user didn't ask Sprig to touch.
   Offering the affordance *on refusal* keeps consent explicit and teaches the failure mode.

## Consequences

- Beginners stop being stranded at the dirty-tree refusal; the work travels or is verifiably
  parked, never lost.
- A second consumer (auto-stash around *pull*, affordances 1.3's other half) reuses
  `StashOps` unchanged; `SyncOps` already passes `merge --autostash` for the checked-out
  branch fast-forward, so pull coverage is partially native.
- The pop-conflict surface ("kept in stash") introduces a new UI banner state the macOS/Windows
  shells must render (M2/M3 shell work; engine ships now).
- `git stash pop`'s exit codes aren't a precise contract; `StashOps` therefore verifies entry
  survival via `refs/stash` and throws loudly on the (never-observed) kept=false failure path
  rather than mis-reporting.

## Links

- Implements `docs/research/git-beginner-affordances.md` item 1.3 (switch half).
- ADR 0033 (safety tiers), 0057 (Commands panel shows the underlying git), 0065 (stash export
  safety net), 0068 (the sibling auto-sync affordance + its `--autostash` fast-forward option).
