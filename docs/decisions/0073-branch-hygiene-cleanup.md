---
status: accepted
date: 2026-06-10
deciders: maintainer (beginner-affordances directive 2026-06-09), engineering
consulted: —
informed: —
---

# 0073. Branch hygiene — "merged on the server; clean it up?"

## Context and problem statement

Affordances item 2.4: after a forge merges a PR it usually deletes the remote branch; the
local branch lingers. Beginners accumulate dozens, and the branch list stops being a map of
in-flight work — a real comprehension cost. The signal is already in hand since ADR 0068:
post `fetch --prune`, the branch's upstream is *gone*.

The risk that keeps this from being a trivial `branch -d` loop: a deleted-on-the-server
branch may still hold commits that exist nowhere else (closed-unmerged PRs, force-cleaned
remotes). Deleting those without ceremony is exactly the data loss ADR 0033 tiering exists
to prevent.

## Decision

**Detection** (`GitCore.BranchHygiene.staleBranches()`): branches with `upstreamGone`,
classified against the **remote default branch** (`refs/remotes/origin/HEAD`, falling back to
`origin/main` / `origin/master`; no baseline ⇒ the affordance stays quiet):

- `merge-base --is-ancestor <branch> <remote-default>` and not checked out ⇒ **safe** —
  deleting loses nothing.
- otherwise `rev-list --count <branch> ^<remote-default>` ⇒ the **unpushed-commit count** the
  confirmation shows.

**Two cleanup verbs** (`TaskWindowKit.BranchHygieneViewModel`), tiered per ADR 0033 via
`DestructiveOpTier.tier(for: opBranchDelete)`:

| Verb | Gate | Mechanics |
|---|---|---|
| `cleanUp` | classified safe only | `git branch -D` on the strength of the ancestor proof |
| `cleanUpKeepingSafetyCopy` | any stale, not checked out | snapshot the tip under `refs/sprig/snapshots/…/branch-delete` (SafetyKit), then `git branch -D`; the snapshot ref is surfaced for the 24 h undo banner |

**Why the safe verb is `-D`, not `-d`** (decided by a failing test): `git branch -d`'s
merged-check is calibrated against **HEAD**, which false-refuses the *canonical* scenario —
the server merged the branch but the local default branch hasn't pulled that merge yet. Our
ancestor-of-remote-default proof is the real guarantee; `-d` would re-ask the wrong question.
`deleteBranch` (`-d`) remains in GitCore for callers wanting git's HEAD-baseline semantics,
with typed refusal outcomes.

Banner copy lives in `StatusVocabulary` (ADR 0072), both registers — the unsafe variant
states the count and that a safety copy is kept first.

TaskWindowKit gains the `SafetyKit` Tier-1 dependency (the tier table's intended consumer —
its docs predicted "typically a destructive-op task window's view model").

## Considered options

1. **Classified two-verb cleanup with snapshot pairing** (this ADR).
2. Auto-delete safe branches silently after fetch — mutating refs without consent breaks
   trust and ADR 0064's "visibility" principle; offering is the affordance.
3. `git branch -d` for the safe verb — false-refuses the common case (above).
4. Defer everything to a "Branches" manager window — the moment of relevance is *right after
   the fetch that pruned the upstream*; a parked manager loses the teachable moment. (A
   manager surface can still consume the same engine later.)

## Consequences

- The branch list tends back toward "my in-flight work"; every deletion is either provably
  lossless or snapshot-backed with a visible undo path.
- The Status/auto-sync surfaces can show "2 branches can be cleaned up" from the same
  `staleBranches()` read the hourly fetch already enables.
- Restore-from-safety-copy is `git branch <name> <snapshot-ref>` — the Recover task window
  (ADR 0033 amendment) gets branch-delete entries for free since the op tag is standard.

## Links

- Implements `docs/research/git-beginner-affordances.md` item 2.4.
- ADR 0033 (tiering + snapshot refs; `opBranchDelete` is medium), 0065 (stash safety
  sibling), 0068 (the prune that creates the signal), 0072 (banner copy).
