---
status: accepted
date: 2026-04-24
amended: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0033. Destructive-op safety — tiered with snapshot refs

## Context

See the master plan at `/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md`, §3 (Decision Log) for the original rationale, alternatives, and consequences.

## Decision

Captured in the plan. Three-tier confirmation model (Low / Medium / High) plus an automatic snapshot ref under `refs/sprig/snapshots/<timestamp>/<op>` before every destructive operation. Snapshots auto-prune after 30 days (configurable).

## Consequences

See the plan for trade-offs. When implementation reveals new consequences, update this file and cite the commit.

---

## Amendment 2026-05-02 — Add visible "Recover" UI surface (per §13.3-A)

### Why amend

The original ADR specified the snapshot-ref machinery but left the user-visible surface unspecified. Field reports across the macOS GUI competitive review (master plan §13) consistently show that **the safety net is only effective if users can find it**: GitUp's snapshot sidebar, Tower's labeled undo button, and Retcon's pervasive ⌘Z are the cited "I won't lose work" trust signals. A snapshot ref users can't see or use without a CLI does not deliver that signal.

### Decision (amendment)

Sprig surfaces snapshot refs through three coordinated UIs:

1. **A new "Recover" task window**, launched via right-click → Sprig ▶ → Recover…. Shows a vertical, timestamped list of the right-clicked repo's `refs/sprig/snapshots/...` entries. Each entry: the operation that produced it (`merge`, `rebase`, `reset-hard`, `stash-drop`, `force-push`, etc.), the timestamp, and a "View diff against current HEAD" button. Selecting an entry shows a unified diff in the right pane. A primary "Restore" button re-checks-out HEAD to the snapshot, with a secondary confirmation (snapshot becomes the new HEAD; current HEAD is itself snapshotted first under a new ref). Tier-1 portable `RepoState` work + a Tier-3 task-window UI in `apps/macos/SprigApp/Sources/TaskWindows/RecoverWindow/` (and its Windows analogue).
2. **A header strip on every destructive-op task window** (MergeConflictResolver, RebaseInteractive, BranchSwitcher when deleting unmerged branches, ForcePushDialog, ResetDialog, StashDropConfirm, etc.) — single-line: `Snapshot: refs/sprig/snapshots/<op>-<ts>` + a "Revert this operation" button. Same restoration semantics as the Recover window's button.
3. **`sprigctl recover --list <repo>` and `sprigctl recover --restore <ref>`** for headless / CLI usage. Stays consistent with the GUI's restoration semantics so users moving between surfaces never see different behavior.

### Implementation notes

- The Recover task window is *opened on demand from a right-click verb*. There is no persistent "Recover" sidebar or main-window entry — preserving the Finder/Explorer-first invariant per ADR 0030.
- `RepoState` package gains a `SnapshotIndex` actor that lists / queries / prunes snapshot refs without spawning git per query (uses `for-each-ref refs/sprig/snapshots/`).
- The header strip is a `TaskWindowKit` primitive so every destructive-op window inherits it without per-window plumbing.
- Restoration creates a *new* snapshot ref of the current HEAD before checking out the older one. Restoration is itself reversible.
- Snapshot refs older than the configured TTL (default 30 days) are pruned by a background job triggered on agent startup; the Recover window shows a "<N> older snapshots auto-pruned" footer when the user has had this repo open longer than the TTL.

### Consequences

**Positive**
- Closes the "users don't know snapshots exist" usability gap that produced GitUp's complaints.
- Makes the safety net a marketing differentiator: "the only Mac client where every destructive op is one-click reversible."
- Stays inside the Finder/Explorer-first invariant — Recover is a verb, not a permanent UI place.

**Negative / trade-offs**
- New task window adds Tier-3 surface area; needs design + a11y review like every other task window.
- Snapshot listing on huge repos (`for-each-ref refs/sprig/snapshots/`) needs to be paginated; the Recover window shows the most recent 100 by default with a "Show older" affordance.
- Restoration's "snapshot HEAD before restoring" rule doubles snapshot ref count for users who use Recover heavily; pruning compensates.

## Amendment 2026-06-11 — Recover VM shipped; restores never eat uncommitted work

The portable half of the 2026-05-02 surface is implemented: **`TaskWindowKit.RecoverViewModel`**
presents ONE newest-first list (`RecoveryPoint`) merging this ADR's snapshots with ADR 0075's
backups — for the user, "Sprig's safety copies" is one concept regardless of which engine
minted the ref. Two fail-closed restore verbs:

- `restoreBackup` — `WorktreeBackup.restore`'s additive worktree write (ADR 0075 semantics).
- `restoreSnapshot` — `reset --hard`, with **two insurance refs taken first**: the dirty
  working tree (tracked + untracked) goes into an ADR 0075 backup — the original CLI flow
  protected committed state only and would eat uncommitted work — and pre-restore HEAD gets
  its own snapshot (`SnapshotRefName.opRestore`, now a shared constant), keeping restores
  self-reversible. `sprigctl recover --restore` gains the same uncommitted insurance.

Hardening found by the round-trip test: two restores inside one second mint the **same**
`<ts>/restore` before-snapshot name, so an immediate undo would have its target overwritten
by its own before-snapshot before the reset read it. Both surfaces now pin the restore
target to its resolved SHA before minting any refs — the same collision class ADR 0075
fixed for backup refs. Non-Sprig refs are rejected before any git runs (`reset --hard
<arbitrary-ref>` is a different, more dangerous verb than Recover). The Tier-3 windows and
the per-window header strip remain M3 work.

## Amendment 2026-06-18 — Same-second snapshots uniquify instead of overwriting

The S2 `SnapshotWriter` originally let two snapshots minted in the same wall-clock
second with the same op tag collide on one ref name; the second `git update-ref`
overwrote the first, silently losing a safety snapshot — the exact failure the
snapshot exists to prevent. `createSnapshot(op:target:)` now pins the target to a
resolved object id up front, then **atomically** mints the first free
`…/<ts>/<op>[-N]` slot: the first collision yields `…/<ts>/<op>-2`, a third `-3`, and
so on. The write uses `git update-ref --stdin`'s `create`, which verifies the ref does
not exist *under the ref lock* before writing — so even two independent processes (the
agent's auto-sync rebase vs. a task-window op on the same repo) racing for the same name
can't both win: the loser fails closed and advances to the next suffix instead of
blind-overwriting the winner's snapshot. The `-N` suffix stays inside
`SnapshotRefName.isValidOp` (`[a-z][a-z0-9-]{0,63}`) and the read path
(`RepoState.SnapshotIndex`) treats it as an opaque op tag, so every snapshot survives
and stays enumerable / recoverable — generalizing, to *all* destructive ops, the
collision fix the 2026-06-11 amendment applied to the restore flow. A
`collisionLimitExceeded` runaway guard fails closed past `sameSecondLimit` collisions or
when the suffix would overflow the 64-char op cap.

**Consumer audit (op-family matching).** The Recover surface restores an `opStashDrop`
snapshot with `git stash store` (it points at a dropped stash *commit*) rather than the
`reset --hard` every other op uses. Both restore sites classified by exact op string, so
a uniquified `stash-drop-2` would have fallen through to a destructive `reset --hard`
onto the stash commit — a corruption path the uniquifier itself introduced.
`SnapshotRefName.baseOp` (strips a trailing `-<digits>`) now backs both comparisons,
with CLI + VM round-trip tests restoring a `stash-drop-2` ref and asserting the stash
list — not HEAD — moves. No known op constant ends in `-<digits>`, so the strip is
unambiguous. (Caught by the adversarial review panel, not by the green unit tests — the
store-vs-reset hazard the undo round-trip rule exists to catch.)

(`WorktreeBackup` solves the identical same-second class for its branch-labelled refs by
bumping the timestamp one second per collision; snapshot refs use the op-suffix because
their `<ts>/<op>` shape has a clean suffix slot the backup refs lack. As of this
amendment `WorktreeBackup.mintBackup` writes through the **same atomic
`git update-ref --stdin` `create`** as `SnapshotWriter` — verifying non-existence under
the ref lock and advancing the loser to the next second instead of overwriting — so the
two engines are now consistent. This closes the former probe-then-write TOCTOU it left
open: two same-second backups of one branch (the agent's auto-backup vs. a restore's
fail-closed pre-backup) could both probe a name vacant and the second blind-overwrite
the first, silently losing a backup. Low severity for a single-user desktop tool, but it
was the last residual instance of the exact failure class this amendment exists to
close.)

## Links

- Master plan §3 (original 0033) and §13.3-A (amendment).
- CLAUDE.md — summarizes load-bearing rules across multiple ADRs.
- Related ADRs: 0030 (Finder-first architecture), 0034 (no menu-bar helper), 0066 (stale `index.lock` recovery surfaces alerts via the same Notification Center channel).

## Implementation map

- `packages/SafetyKit/Sources/SafetyKit/SnapshotRefName.swift` — wire-stable ref-name format (slice S1).
- `packages/SafetyKit/Sources/SafetyKit/SnapshotWriter.swift` — `createSnapshot(op:target:)` pins the target SHA then atomically creates the first vacant `…/<ts>/<op>[-N]` ref via `git update-ref --stdin` `create` (S2; same-second uniquifier per 2026-06-18 amendment); `withSnapshot(op:target:_:)` wraps any destructive op with an auto-snapshot (S4) — body's throw rethrows, but the ref persists.
- `packages/SafetyKit/Sources/SafetyKit/SnapshotRefName.swift` — `baseOp` strips the `-<digits>` uniquifier so op-family consumers (Recover's stash-drop classifier) match `stash-drop-2` like `stash-drop`.
- `packages/SafetyKit/Sources/SafetyKit/WorktreeBackup.swift` — `mintBackup(commit:branch:startingAt:)` writes ADR 0075 backup refs through the same atomic `git update-ref --stdin` `create`, bumping the timestamp one second per collision (its analog of the op-suffix); per the 2026-06-18 amendment, closing the cross-engine TOCTOU gap.
- `packages/RepoState/Sources/RepoState/SnapshotIndex.swift` — read + prune path (S3 per amendment §13.3-A).
- `packages/SafetyKit/Sources/SafetyKit/DestructiveOpTier.swift` — three-tier confirmation policy data type (`.low` / `.medium` / `.high`) with `requiresSnapshot`, `requiresTypedPhrase`, `undoBannerPolicy` accessors and a fail-closed `tier(for: opTag)` lookup (S5).
- `apps/{macos,windows}/.../TaskWindows/RecoverWindow/` — Recover task window (Tier 3, separate from SafetyKit).
- `cli/sprigctl/.../RecoverCommand.swift` — `sprigctl recover --list | --restore` (separate CLI work).
