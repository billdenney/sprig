---
status: accepted
date: 2026-06-11
deciders: maintainer (standing "lean in further and proceed"), engineering
consulted: —
informed: —
---

# 0083. Interactive-rebase engine — a printf todo over git's own sequencer

## Context and problem statement

M5's Rebase window (and ADR 0051's stacked-PR workflows above it) needs an engine that
executes "reorder these commits, fold those, drop that one" — the drag-and-drop list
every rebase UI is. The design tension: `git rebase -i` owns exactly the state machine
we want (conflict parking, `--continue`/`--abort`, reflog entries, hooks), but it is
built around an interactive editor. Reimplementing the replay with cherry-pick loops
would give us full control and cost us the entire state machine — plus a Sprig-private
"remaining plan" file that `git rebase --abort` knows nothing about. That fights
defer-to-git (ADR 0023) head on.

## Decision

**`GitCore.RebasePlanOps` drives git's own sequencer, injecting the todo through a
one-shot `sequence.editor` whose command is a `printf` redirect — no shipped scripts,
no embedded editor.** Spiked before building, test-pinned after:

- Todo lines are strictly `<verb> <40-hex-sha>`; the SHA charset is **validated before
  interpolation**, so the editor command needs no quoting and cannot be injected (a
  malformed SHA — including shell metacharacters — is a typed `invalidPlan` refusal,
  pinned). Git invokes editors through its own sh on every platform, including Git for
  Windows' bundled sh, so the trick is as portable as git itself.
- **The editor-free verb set (v1): `pick`, `fixup`, `drop`, plus reordering by todo
  order.** `squash` and `reword` open git's *commit* editor mid-run; they ride
  ADR 0082's reword and a later message-editing slice. `fixup` covers "absorb these
  WIP commits" without an editor.
- **Plan validation**: the plan must cover each unpushed commit exactly once (drops
  explicit, never implicit — `rebase.missingCommitsCheck` leniency is not a contract),
  and may not start with a fixup. An all-drop plan is valid (branch ends at the base).
- **Range and base**: the rewritable range is the ADR 0082 oracle (`HEAD --not
  --remotes`, oldest first = todo order); the base is `HEAD~count`, or `--root` when
  the range reaches the first commit (a repo with no remotes rewrites everything).
- **Safety contract** = ADR 0082's set plus the dirty-worktree refusal a
  worktree-touching replay needs: unpushed-only, no staged changes, no parked
  midstream op, clean tracked worktree, on a branch.
- **Conflicts park git's rebase**, typed `conflicted(conflictedPathCount:)` — the M4
  resolver owns `--continue`/`--abort` through the machinery it already has
  (`MidstreamOperation` detects the markers), and `rebase --abort` returns to the
  exact pre-plan tip (pinned). `RebasePlanViewModel` mints the ADR 0033 medium-tier
  snapshot (existing `rebase` op tag) at the pre-plan tip before anything replays, so
  a COMPLETED plan is also one restore away (Recover round-trip pinned).

## Considered options

1. **printf sequence.editor over `rebase -i`** (this ADR) — git owns the state machine.
2. Cherry-pick replay loop — full control, but reimplements rebase, leaves Sprig-only
   state `--abort` can't see, and forfeits hooks/reflog semantics. Rejected.
3. `GIT_SEQUENCE_EDITOR` pointing at a shipped helper script — works, but means
   installing and locating a script per platform; the printf form carries the todo in
   the config value itself. Rejected as needless surface.
4. `git replay` (new plumbing) — promising long-term, but too new for the pinned git
   floor (2.39) and has no conflict-parking story yet. Revisit when the matrix moves.

## Consequences

- The Rebase window binds `commits` (oldest-first; render reversed), `state`,
  `conflictedPathCount`, `lastSafetyCopy`. Drag-reorder UIs serialize directly into
  `[RebaseStep]`.
- Message editing inside a plan (reword/squash-with-message) is a follow-up slice —
  it needs a GIT_EDITOR strategy with per-commit messages, which deserves its own
  design rather than a bolt-on.
- ADR 0051's stacked flows get their substrate: replaying a child branch onto a moved
  parent is this engine pointed at a different base (follow-up).

## Links

- ADR 0023 (defer to git), 0033 (tier policy), 0051 (stacked-PR umbrella),
  0082 (the shared safety contract + oracle).
- `packages/GitCore/Sources/GitCore/RebasePlanOps.swift`,
  `packages/TaskWindowKit/Sources/TaskWindowKit/RebasePlanViewModel.swift`.
