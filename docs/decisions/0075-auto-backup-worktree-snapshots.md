---
status: accepted
date: 2026-06-10
deciders: maintainer (beginner-affordances directive 2026-06-09), engineering
consulted: —
informed: —
---

# 0075. Auto-backup — Time-Machine-style insurance for uncommitted work

## Context and problem statement

Affordances item 2.2, the last medium item of the backlog: the user who hasn't learned to
commit often has zero insurance — a bad `discard`, an editor mishap, or a crash deletes hours
of work that never reached any git object. ADR 0033's snapshots protect *committed* state
around destructive ops; nothing protects the working tree between commits.

Constraints that shape the design: no history pollution (collaborators must never see
backups), no hooks (a backup must never trigger the user's commit machinery), no worktree /
index / HEAD side effects (an invisible safety net, not a background committer), and bounded
growth.

## Decision

**`SafetyKit.WorktreeBackup` snapshots a dirty working tree into commits reachable only from
`refs/sprig/backup/<ts>/<branch-label>`**, on a 30-minute default cadence driven by the agent.

Mechanics (all plumbing): dirty check via porcelain; a **throwaway index** (`GIT_INDEX_FILE`
override) runs `read-tree HEAD` (or `--empty` on an unborn branch) → `add -A` →
`write-tree`; `commit-tree -p HEAD` → `update-ref`. Tracked changes AND untracked files are
captured; the real index, worktree, HEAD, and hooks are untouched (commit-tree runs no
hooks). Identical-tree dedup means a dirty-but-unchanged tree across ticks reuses the
existing ref.

**Correctness details that earned tests:**
- **Same-second collisions must not clobber** (found by a failing CLI test): restore's
  fail-closed pre-backup can land in the same second as the backup being restored — minting
  the same ref name would overwrite the restore source with the about-to-be-replaced state.
  Refs are therefore minted collision-avoiding (+1 s per occupied slot, bounded), and restore
  pins the source to its commit SHA before the pre-backup runs.
- **Restore is fail-closed and additive**: current dirty state is backed up first (so restore
  can be undone), `git restore --source=<sha> --worktree -- :/` writes the backup's files,
  files created after the backup survive, the index is untouched.

**Lifecycle + bounds**: the agent (`AutoBackupStartup`, reusing the generic
`AutoSyncScheduler`) runs the tick — backup-if-dirty then TTL prune (default 7 days). Deleted
refs make the commits unreachable; normal `git gc` reclaims the objects. Preferences:
`autoBackupEnabled` (default **on** — pure-local, invisible, bounded),
`autoBackupIntervalMinutes` (30), `autoBackupTTLDays` (7). CLI: `sprigctl backup
--list/--now/--restore`.

## Considered options

1. **Off-branch backup commits via throwaway index** (this ADR).
2. `git stash create` on a timer — no untracked support without store-side effects, pollutes
   the stash list users interact with, and ADR 0065's export net would multiply entries.
3. Auto-commit to a real temp branch — appears in branch lists, runs hooks via porcelain
   commit, and rewires the beginner's mental model of "commit" as something Sprig does to
   them.
4. Filesystem-level copies outside git — loses content dedup, diffability, and the existing
   Recover surface; reinvents object storage badly.
5. Default-off — insurance that's off protects no one; the costs (local objects, TTL-bounded)
   are small and invisible. Off remains one toggle away.

## Consequences

- A beginner's never-committed work survives crashes and oopses up to the tick interval; the
  Recover/undo surfaces gain a "your uncommitted work from HH:MM" dimension (shell UI rides
  M2/M3).
- Repo object growth is bounded by TTL + gc; worst case is transient (large dirty files →
  blobs that expire in 7 days). A size guard (skip > N MB with a banner) is noted as a future
  refinement if real-world repos surface pathological cases.
- `refs/sprig/backup/*` joins `refs/sprig/snapshots/*` in the "never delete without
  respecting TTL" covenant (CLAUDE.md).

## Amendment — backup deny-list (maintainer-ratified 2026-06-11)

Backups now **exclude likely secrets and tool temporaries** at staging time. An auto-backup
default-on engine that quietly persists an unignored `.env` into git objects every 30 minutes
converts "file on disk" into "blob recoverable for the whole TTL window" — a meaningful
escalation for credential material; for Office `~$` lock files and editor swap files it's
pure noise. The maintainer ratified the deny-list as the standard secret set **plus**
typical temporary files.

Mechanics: the rules live in `GitCore.JunkFilePatterns` (one curated list, two projections);
`WorktreeBackup` appends `:(exclude,glob)**/<pattern>` pathspecs to the throwaway-index
`add -A`. A tree dirty *only* with excluded files produces **no backup** (the staged tree
equals HEAD's tree — same dedup logic as the identical-state case, so junk-only repos don't
mint a ref every tick). The list is injectable (`excludedPatterns:`) for the future
Preferences-driven override.

Known trade-off (documented in code): name-based rules (`*credentials*`, `*secret*`) can
match legitimate work files, which are then silently not backed up. Accepted — a leaked
secret is worse than a narrower insurance net — and mitigated by the ADR 0070 amendment's
`.gitignore` suggestion, which surfaces exactly these files to the user with a durable fix.

## Links

- Implements `docs/research/git-beginner-affordances.md` item 2.2 — the final backlog item;
  with this, every 1.x and 2.x affordance is engine-shipped.
- ADR 0033 (snapshot refs sibling + ref-namespace covenant), 0064/0068 (scheduler + policy
  seam reuse), 0065 (stash safety relative), 0023 (defer-to-git plumbing), 0070 amendment
  (the `.gitignore` suggestion pairing).
