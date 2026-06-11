---
status: accepted
date: 2026-06-11
deciders: maintainer (standing "lean in further and proceed"), engineering
consulted: —
informed: —
---

# 0079. Stash browser — SHA identity, and the only drop keeps a safety copy

## Context and problem statement

ADR 0069 made Sprig *create* stash entries on the user's behalf (auto-stash around branch
switch; the conflicted-pop "kept in stash" outcome). Once software sets work aside
automatically, "where did my set-aside changes go?" needs a first-class answer — a browser
with apply / pop / drop verbs. Two design hazards drive the decisions:

1. **Reflog selectors are unstable.** `stash@{N}` reindexes whenever any entry is popped
   or dropped. A browser that holds a list while the world changes (another window, the
   CLI, the auto-stash itself) and then acts by selector can destroy the *wrong* entry.
2. **Every stash entry is unsaved work.** Unlike branch hygiene (ADR 0073), where a
   server-merged branch is provably safe to delete, there is no "already safe" stash
   entry — a stash is by definition work recorded nowhere else, so dropping is always
   ADR 0033 medium tier.

## Decision

**Engine (`GitCore.StashOps`, by-ref verbs):** `list()` parses
`git stash list --format=%gd%x00%H%x00%cI%x00%s` (NUL-delimited fields; subjects can't
break the parse) into `StashEntry` — selector, **commit SHA**, date, subject. `apply(ref)`
never drops; a non-zero exit is the typed `.conflicted(detail:)` (entry verifiably kept).
`pop(ref)` reports `.keptDueToConflict` only after confirming the entry's **SHA** still
appears in the stash reflog — selector indices shift, SHAs don't. `drop(ref)` returns the
dropped commit's SHA. All outcome detection is plumbing-based, per ADR 0069.

**View model (`TaskWindowKit.StashViewModel`): verbs re-resolve by SHA before acting.**
Every verb re-lists and locates its `StashEntry` by commit SHA, acting on the entry's
*current* selector. A stale list can therefore never misfire onto a neighbor entry; a
vanished entry (applied/dropped elsewhere) is a worded validation failure and the list
self-corrects. Conflicted apply/pop is a worded failure too — markers in the files, copy
kept, nothing lost.

**The only drop verb is `dropKeepingSafetyCopy`.** Per hazard 2 there is no plain drop:
the VM consults `DestructiveOpTier.tier(for: opStashDrop)` (medium) and snapshots the
stash **commit** under `refs/sprig/snapshots/<ts>/stash-drop` *before* dropping — a
dropped entry's commit is otherwise unreachable (stash reflog entries don't linger).

**Recover restores stash-drop copies with `git stash store`, not `reset --hard`.** A
stash-drop snapshot points at the dropped stash *commit*, not a repo state; resetting to
it would wrongly move the branch onto the stash commit. Both Recover surfaces
(`RecoverViewModel.restoreSnapshot`, `sprigctl recover --restore`) branch on the `op` tag:
`stash-drop` → `git stash store -m <original subject> <sha>` — additive, worktree and HEAD
untouched, no insurance refs needed. The drop → restore round-trip preserves the entry's
SHA and subject exactly (test-pinned on both surfaces).

The window's "set aside now" button binds to ADR 0069's existing `StashOps.push`; no new
create verb. A `sprigctl stash` CLI face is a noted follow-up.

## Considered options

1. **By-SHA re-resolution + safety-copy-only drop** (this ADR).
2. Act by held selector (`stash@{N}` from the last refresh) — simplest, but races every
   other stash mutator and destroys the wrong entry when it loses. Rejected — this is the
   browser's one unforgivable failure mode.
3. Plain drop with a confirm dialog — confirmation is not recovery (ADR 0033's premise);
   a snapshot ref costs nothing and makes the dialog *honest* ("Sprig kept a safety
   copy"). Rejected.
4. Restore stash-drop copies via the existing `reset --hard` path — wrong semantics
   (moves the branch onto a stash commit). Rejected; this is why the op-tag branch exists.

## Consequences

- The Stash task window binds to `entries`/`state`/`lastSafetyCopy`; the undo banner's
  restore action routes to the Recover surface like every other safety copy.
- `RecoverOutcome` gains `restoredStashEntry`; shells render it without the insurance-ref
  affordances (none are minted on this path).
- Snapshot TTL pruning applies to stash-drop copies like any other snapshot ref — the
  24 h medium-tier undo window (ADR 0033) is the contract.

## Links

- ADR 0069 (set-aside primitives this browses), 0033 (tier policy + snapshot refs),
  0073 (the contrasting "provably safe" delete), 0072/amendment (vocabulary table the
  worded failures live in).
- Extends `docs/research/git-feature-inventory.md` tier-1 stash coverage.
