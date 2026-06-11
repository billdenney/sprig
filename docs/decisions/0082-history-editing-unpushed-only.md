---
status: accepted
date: 2026-06-11
deciders: maintainer (standing "lean in further and proceed"), engineering
consulted: —
informed: —
---

# 0082. History editing — unpushed-only, snapshot-first (reword + squash)

## Context and problem statement

Master plan §10 names "Reword Last Commit" and "Squash Commits" as right-click verbs.
They're the two history edits beginners actually want ("typo in my last commit
message", "fold these WIP commits before pushing") — and the two with a famous
failure mode: rewriting commits that are already on the server, which forces a
force-push and breaks everyone else's pulls. The second classic trap is subtler:
`git commit --amend` silently folds whatever is *staged* into the rewritten commit.

## Decision

**`GitCore.HistoryOps` offers `rewordLastCommit(message:)` and
`squashLast(count:message:)` under two hard contracts, with
`TaskWindowKit.HistoryEditViewModel` pairing every edit with an ADR 0033 medium-tier
snapshot:**

1. **Unpushed only.** A commit reachable from ANY remote-tracking ref is shared
   history; both verbs refuse with the typed `refusedShared` (`git branch -r
   --contains` is the oracle). For squash the check runs on the OLDEST affected
   commit — a remote containing a child contains its ancestors, so one check covers
   the range. Sprig never offers the rewrite-then-force-push road (CLAUDE.md hard
   rule 7 stays intact by construction).
2. **No silent content changes.** Both verbs refuse when the index differs from HEAD
   (`refusedStagedChanges`), so a reword is message-only (tree/parent/author pinned
   byte-identical) and a squash is exactly the N commits' content (the new commit's
   tree is the old tip's tree, pinned). Remaining guards: parked merge/rebase,
   detached HEAD, unborn HEAD, and ranges that would swallow the root commit
   (`refusedNotEnoughHistory` — root rewrites need different mechanics and aren't
   offered).

Mechanics defer to git: reword is `commit --amend -m` (hooks run), squash is
`reset --soft HEAD~N` + `commit -m`. New op tags `reword` and `squash` join the
medium tier; the VM mints the snapshot at the pre-edit HEAD **before** the rewrite,
so Recover's standard `reset --hard` path is the one-click undo (round-trip
test-pinned). VM pre-guards (empty message, count bounds, nothing-unpushed via its
refreshed `unpushedCount`) are worded validation failures that spawn nothing — the
common refusals never even mint a snapshot; the engine re-checks everything
fail-closed for the rare race.

## Considered options

1. **Unpushed-only with typed refusals** (this ADR).
2. Allow shared-history rewrites behind the high tier (typed-phrase + force-push) —
   the power-user path; deliberately NOT offered in v1. If it ever lands it is a new
   ADR with `--force-with-lease --force-if-includes` plumbing, not a quiet upgrade.
3. Interactive rebase as the engine (`rebase -i` with a scripted todo) — the general
   tool (M5's full rebase UI will need it), but for these two verbs `--amend` and
   `reset --soft` are exact, simpler, and leave no rebase state to abort.

## Consequences

- The Reword/Squash task windows bind `unpushedCount` (squash slider bound),
  `lastSubject` (reword prefill), `state`, `lastSafetyCopy`.
- Squashing through the root commit is refused; squashing *everything after* the
  root works (the root is a valid new parent).
- M5's interactive-rebase engine can reuse the same guard set and op-tag pattern.

## Links

- ADR 0033 (tier policy), 0071 (the never-forces principle this preserves),
  master plan §10 (the verb list).
- `packages/GitCore/Sources/GitCore/HistoryOps.swift`,
  `packages/TaskWindowKit/Sources/TaskWindowKit/HistoryEditViewModel.swift`.
