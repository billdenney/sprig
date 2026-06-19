---
status: proposed
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0088. Agent-review surface — review, stage, and split external-agent commits per worktree

## Context and problem statement

ADR 0056 already makes Sprig aware of external git activity: `AgentKit.RepoAgent` watches
`.git/`, linked worktrees, and submodules, and defers while another process holds a lock
(`GitMetadataPaths.gitOperationInFlight` / `repoIsMidOperation`). Increasingly, the "external
process" is an AI coding agent (Claude Code, Cursor, aider, Copilot CLI) or a teammate's
terminal making commits and working-tree changes the user then needs to review. No competing
GUI treats agent-authored changes as a first-class review object, and the awareness plumbing
to build it already exists.

## Decision drivers

- The awareness layer (ADR 0056) is shipped; this is a surface on top, not new plumbing.
- Review must be safe-by-default: read first, and any rewrite is user-initiated + snapshotted.
- Sprig does not need to identify *which* agent — it notices repo changes it did not author.

## Considered options

1. **An `AgentReviewViewModel` task window fed by `RepoAgent` change detection** (this ADR).
2. Fold it into the existing Status window — buries a review workflow inside a status read.
3. Do nothing; rely on the generic Log/Diff windows — misses the "these N commits arrived
   from outside; review them as a unit" framing that makes the workflow valuable.

## Decision

**Add per-worktree detection of externally-authored change to `AgentKit.RepoAgent` and an
`AgentReviewViewModel` (TaskWindowKit) surfaced as "Review external changes…".** Detection
heuristic (no agent attribution): HEAD moved, or commits/working-tree changes appeared, that
Sprig's own verbs did not initiate, scoped per worktree (reusing `GitMetadataPaths`
worktree/submodule enumeration). The window offers:

- View the diff of the external commits / working-tree changes as a reviewable set.
- **Stage/unstage selectively** and **split a commit** — reuse the region-staging engine
  (ADR 0061) and `CommitComposer`; a split is `reset --soft` + region staging, never a
  silent rewrite.
- **Undo** the external change via the existing recover path (snapshot/backup, ADR 0033/0075).

Strictly review-and-stage by default; every history-rewriting action is user-initiated, goes
through the tiered destructive-op confirmation, and mints a snapshot first.

Deferred: a full worktree-management task window (the power-user `worktree` verb on the
M5–M8 inventory) — this ADR consumes worktree enumeration but does not own creating/removing
worktrees.

## Consequences

**Positive**
- A genuinely novel, differentiating surface; squarely useful for agent-assisted workflows.
- Reuses ADR 0056/0061/0033/0075 rather than introducing new subsystems.

**Negative / trade-offs**
- "Did Sprig author this?" needs a reliable provenance signal (e.g., tagging Sprig-initiated
  operations) so the heuristic doesn't flag the user's own GUI commits — call this out in impl.

## Prerequisites status

Both blockers are now built (the surface itself is still to come):

- **Region staging (ADR 0061)** — `GitCore.DiffPatchSlicer`, the substrate for "split a commit"
  (`reset --soft` + region staging). Shipped.
- **Provenance signal** — `GitCore.OperationProvenance` answers "did Sprig author this commit?".
  It records the SHAs Sprig's verbs create (`recordAuthored`) plus a `recordHeads` ref→sha
  checkpoint, in a **file** at `<git-common-dir>/sprig/provenance.json` — local (never pushed),
  repo-global across worktrees, and gc-neutral (a ref would *pin* the commit, the opposite of
  what provenance wants). Consumers call `authoredCommits()` / `externalCommits(among:)` /
  `lastKnownHeads()`. `CommitComposerViewModel` records every commit it makes; **wiring the
  other commit-producing verbs (merge, rebase, squash, revert, restack, cherry-pick) is part of
  this ADR's slice** — until then their commits would read as "external", so do that wiring
  before the detection heuristic ships.

## Links

- Builds on ADR 0056 (external-agent awareness), 0061 (region staging), 0033/0075
  (snapshots/backups for undo). Relates to the `worktree` power-user verb (feature inventory).
