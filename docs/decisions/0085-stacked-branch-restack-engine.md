---
status: accepted
date: 2026-06-11
deciders: maintainer (ratified the trunk-immutability safety model in-session), engineering
consulted: —
informed: —
---

# 0085. Stacked-branch restack engine — frozen fork-point over git's rebase

## Context and problem statement

ADR 0051 makes stacked-branch workflows first-class and names its restack verb as "the
rebase-plan engine pointed at a moved parent base." This ADR is the engine half: when a
parent branch in a stack (`main` ← `feature-a` ← `feature-b` …) moves, replay each
child's OWN commits onto its parent's new tip. The primitive is `git rebase --onto
<new-base> <fork-point> <child>`; the entire difficulty is choosing `<fork-point>`
correctly, and reconciling restack with the "shared history is immutable" principle (a
stacked PR's branches are pushed by definition).

## Decision

**`GitCore.StackOps` records two local git-config keys per stacked child and restacks
with the FROZEN fork-point:**

- `branch.<child>.sprigParent` = the parent branch name (ADR 0051's ratified key).
- `branch.<child>.sprigBase` = the 40-hex fork commit, frozen at link time as
  `git merge-base <parent> <child>`, re-frozen to the new parent tip after each
  successful restack.

The replay is `git rebase --onto <parentCurrentTip> <recordedSprigBase> <child>` (run
`throwOnNonZero: false`). Because the recorded fork is the commit where the child
diverged — untouched by a parent reword/squash, which rewrites the parent's commits
*above* the fork — the range `sprigBase..child` always isolates exactly the child's own
commits, for both an append-only parent move and a parent rewrite. Before replaying, a
staleness guard (`git merge-base --is-ancestor <sprigBase> <child>`) refuses
(`.refusedForkPointDiverged`) if the record no longer fits the child, rather than
guessing a live merge-base. On success the fork is re-frozen to the new parent tip.

**Re-freeze across the conflict path (review-hardened).** The re-freeze must also happen
when a restack conflicts and is *continued* by the resolver (which is stack-unaware) —
otherwise the stale fork would replay the parent's orphaned commits on the next restack.
The fix is a self-contained transient key `branch.<child>.sprigPendingBase`: written to
the intended new fork *before* the rebase, promoted to `sprigBase` on clean completion,
and on the *next* restack either promoted (if the child now sits on it — the rebase was
continued) or discarded (if it doesn't — the rebase was aborted). No resolver plumbing;
both continue and abort self-heal. Pinned by a conflict → resolve → parent-reword →
restack regression test.

**Conflict handling and safety** copy the verified siblings (RebasePlanOps ADR 0083 /
SyncOps): a conflict parks git's own rebase for the M4 resolver (`.conflicted(branch:
conflictedPathCount:)` — branch-tagged, since a stack op must say *which* child parked);
`git rebase --abort` returns the child to its exact pre-restack tip. The `restack` op
tag joins the ADR 0033 **medium tier**; `TaskWindowKit.StackRestackViewModel` mints the
snapshot at the branch's pre-restack tip — only on `.completed`/`.conflicted` (a refusal
leaves the repo untouched and mints nothing). It restacks the **checked-out branch
only** (refusing otherwise): the snapshot ref carries no branch identity and the Recover
surface undoes it by resetting the *current* branch, so the branch being restacked must
be the current one or the undo would corrupt the wrong branch (a review-found bug). The
Stack Manager UI switches to the branch before invoking restack.

**Safety model (maintainer-ratified, ADR 0051 amendment).** Restack inherently rewrites
an author-owned feature branch that is pushed by definition. This does NOT violate
master-plan §2.5's "shared history immutable": **§2.5 protects the trunk/parent**, and
restack never rewrites the parent or trunk — they are read-only inputs; the only ref that
moves is the child advancing through its own commits. The child is expected to be
force-pushed afterward (the stacked-PR contract), but **restack itself emits no push** —
publishing the rewritten child is the separate high-tier force-push verb
(`--force-with-lease --force-if-includes`). The shared-history `branch -r --contains`
guard (ADR 0082/0083) is therefore deliberately omitted here.

**v1 scope: the single-child `restack(branch:)` primitive only.** The multi-branch
depth-first `restackDescendants` walk is deferred — it needs the `SnapshotWriter`
same-second-collision uniquifier first (a rapid walk minting several `restack` snapshots
in one wall-clock second would overwrite a branch's undo anchor). `.refusedStackCycle`
is reserved in the outcome enum now so adding the walk is not a breaking change.
`stackChildren(of:)` (the read-only parent-graph inversion) ships now for the
visualization surfaces and the future walk.

## Considered options (fork-point)

1. **Frozen recorded fork-point** (this ADR). Deterministic; survives parent rewrites.
2. **Live `merge-base(newParentTip, child)` at restack time** — rejected, **empirically**:
   a spike showed it works for an append-only move, and git's patch-id dedup even rescues
   a pure parent *reword*, but a **content-changing parent amend produces a spurious
   add/add conflict** (the live merge-base slides down to trunk and replays the parent's
   orphaned commit on top of its rewritten self). The frozen fork restacks all three
   cleanly.
3. **`rebase --fork-point` / reflog inference** — rejected: reflog-dependent, unreliable
   across `gc` and non-interactive environments; not a contract.

## Consequences

- The Stack Manager task window binds `state`, `conflictedPathCount`, `lastSafetyCopy`;
  `stackChildren` feeds the stack visualization.
- A bare `sprigBase` config SHA can be `gc --prune`d between link and restack, surfacing
  as a clean `.refusedForkPointDiverged` the user clears by re-recording — a gc-durable
  ref under `refs/sprig/` is a noted follow-up, not v1.
- The multi-branch walk + the `SnapshotWriter` uniquifier it depends on are the next
  ADR 0051 slices.

## Links

- ADR 0051 (stacked-PR umbrella — amended same day to record the trunk-immutability
  safety model), 0083 (the rebase-plan engine + conflict-park pattern reused),
  0033 (tier + snapshot), 0023 (defer to git).
- `packages/GitCore/Sources/GitCore/StackOps.swift`,
  `packages/TaskWindowKit/Sources/TaskWindowKit/StackRestackViewModel.swift`.
