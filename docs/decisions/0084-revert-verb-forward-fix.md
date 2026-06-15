---
status: accepted
date: 2026-06-11
deciders: maintainer (standing "lean in further and proceed"), engineering
consulted: —
informed: —
---

# 0084. Revert verb — forward-fix, merge commits deferred

## Context and problem statement

Master plan §10 lists "Revert Changes": undo a commit by creating a NEW commit with the
opposite change. It is the safe counterpart to ADR 0082's rewrites — additive, so it is
exactly the verb for commits that are **already shared** (where reword/squash refuse).
Its hazards differ from rewriting: a revert can conflict (the surrounding code moved
on), and reverting a merge commit needs a mainline-parent choice git cannot infer.

## Decision

**`HistoryOps.revert(_ sha:)` runs `git revert --no-edit` under the shared
`HistoryRewriteGuards` set (clean tree required, so the revert commit contains exactly
the inverse change), with typed outcomes for every non-clean path:**

- A conflicted revert **parks git's own revert** (`REVERT_HEAD` — `MidstreamOperation`
  already classifies it): the M4 resolver owns continue/abort, and `git revert --abort`
  returns to the exact pre-revert tip (pinned). Same handoff shape as
  merge/rebase/cherry-pick.
- **Merge commits refuse** (`refusedMergeCommit`, detected via `sha^2`): reverting one
  needs `-m <parent>` and a mainline-choice UI — deferred, not silently guessed.
- Unknown SHAs are `refusedUnknownCommit`, not stderr surprises.

`HistoryEditViewModel.revert(sha:)` pairs it with the ADR 0033 medium tier (existing
`revert` op tag): the pre-revert tip is snapshotted first, so the revert itself is one
Recover restore away (round-trip pinned — the undo-round-trip rule). Three new
vocabulary strings; the remaining refusals reuse the history/rebase wording.

## Considered options

1. **`git revert --no-edit` with typed outcomes** (this ADR).
2. Allowing dirty worktrees (git permits non-overlapping dirt) — rejected: the snapshot
   captures HEAD, not the dirt, and a conflicted revert atop pre-existing changes
   muddles the resolver; clean-tree is the predictable beginner contract, consistent
   with the rebase plan's refusal.
3. Merge-commit revert with an automatic `-m 1` — rejected: silently choosing the
   mainline is exactly the kind of guess that bites later; a parent-picker UI can lift
   the refusal when a surface exists for it.

## Links

- Master plan §10 ("Revert Changes"), §11.7 (recovery UX).
- ADR 0033 (tier + snapshot), 0082 (the shared guard set + contrasting rewrite verbs),
  0034 (the resolver this hands conflicts to).
- `packages/GitCore/Sources/GitCore/HistoryOps+Revert.swift`,
  `packages/TaskWindowKit/Sources/TaskWindowKit/HistoryEditViewModel.swift`.
