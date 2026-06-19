---
status: accepted
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0090. File version history and restore-previous-version — a beginner wrapper over blame/file-history

## Context and problem statement

Per-file history and blame are planned power-user features (M5–M8; the git-backend doc names
`CatFileBatch` as the foundation for "diff / blame / log walking, future history viewer," and
the shell-integration doc references per-file "Blame, History" menu items). For the storage
persona, the most valuable framing of that same machinery is the SharePoint "version history
→ restore this version" affordance: see prior versions of one file and bring one back.

## Decision drivers

- Reuses the planned blame/file-history foundation rather than inventing a new one.
- "Restore a previous version of this file" is a top storage-persona expectation.
- Must be safe: restoring is additive and backs up current work first.

## Considered options

1. **`GitCore.FileHistory` + `FileHistoryViewModel`, with restore via the existing recover safety path** (this ADR).
2. Repo-level Log only — doesn't answer "what happened to *this* file" or restore it.
3. Wait for the full M5–M8 blame work before any restore UI — leaves the highest-value
   beginner affordance unshipped the longest.

## Decision

**Add `GitCore.FileHistory` (`git log --follow -- <path>` for the revision list; per-revision
blob reads via `CatFileBatch`) and a `FileHistoryViewModel` (TaskWindowKit), surfaced as a
per-file right-click "Show History…" / "Restore Previous Version…".** Selecting a revision
shows that version (routed through the ADR 0086 renderers for binaries); **Restore** writes
the chosen blob into the worktree (optionally staged) — additive, never a history rewrite —
and **backs up the current file state first** via `SafetyKit.WorktreeBackup`, mirroring the
fail-closed pattern `RecoverViewModel` already uses (ADR 0033/0075).

Beginner naming leads (plain register): "version history," "restore this version,"
"Sprig saved a copy of your current file before restoring." The same window is the natural
home for blame ("who last changed each line") when that M5–M8 work lands; this ADR may pull
the shared `FileHistory` foundation forward.

Deferred: blame rendering itself (M5–M8), pickaxe/`-S`/`-G` content search, and cross-file
"restore the whole repo to a point in time" (that is the recover/reflog story, ADR 0033).

## Consequences

**Positive**
- Delivers the marquee storage-persona feature on top of already-planned infrastructure.

**Negative / trade-offs**
- `--follow` rename heuristics are imperfect; surface the limitation rather than implying a
  perfect lineage. Restoring a binary via the 0086 path depends on that ADR for preview.

## Implementation notes (2026-06-18)

Shipped as `GitCore.FileHistory`, `SafetyKit.FileBackup`, `TaskWindowKit.FileHistoryViewModel`,
and a `sprigctl file-history <path> [--restore <sha>]` CLI face.

**Revision list + rename lineage.** `FileHistory.revisions(of:)` runs `git log --follow
--name-status --format=…` once and records, per revision, the file's path AS IT WAS at that
commit (the new-name field of the `--name-status` line). This matters because reading an old
revision's blob requires the historical path — `<old-sha>:<current-path>` fails after a
rename. `contents(of:using:)` then reads `<sha>:<pathAtRevision>` through the long-lived
`CatFileBatch` (the documented history/blame foundation, git-backend.md). `--follow`'s rename
detection is git's own heuristic; the lineage it reports is surfaced as-is (no perfect-lineage
claim).

**Single-file backup primitive (`SafetyKit.FileBackup`).** `WorktreeBackup` (ADR 0075) backs
up the whole tree into a commit; for one file that's overkill, so this stores just the file's
current bytes as a **blob** and points a ref at it (`refs/sprig/filebackup/<ts>/<label>`).
Verified empirically: `update-ref` accepts a blob target, `for-each-ref` lists it, and `git
gc` keeps it (a ref is a GC root regardless of object type), so restore is a plain `cat-file
blob` → write (mirroring `MergeApplyPipeline`). Atomic `update-ref --stdin create` +
same-second timestamp-bump collision handling mirror `WorktreeBackup` exactly. Per the ADR,
File History owns this directly rather than wiring into `RecoverViewModel`.

**Restore is fail-closed + additive.** `restore` reads the chosen version, **then** backs up
the file's current (possibly dirty) bytes to a `FileBackup` ref, **then** writes the bytes to
the worktree path — never a history rewrite. The undo round-trip (restore an old version →
restore the backup → byte-exact original) is test-pinned (CLAUDE.md undo rule). Binary
versions are flagged (`isBinary`, NUL-byte sniff) so the UI says "preview only"; restore still
writes binary bytes faithfully. Plain copy lives in `TaskWindowVocabulary`.

**Adversarial review hardened (before merge):** (1) `revisions(of:)` uses `git log -z` —
without it `--name-status` C-quotes non-ASCII paths (`café.txt` → `"caf\303\251.txt"`),
which would feed a bogus `<sha>:<quoted>` to cat-file and break show/restore for accented /
CJK / emoji filenames; (2) `FileBackupRefName.sanitize` percent-encodes everything outside
`[A-Za-z0-9_-]`, which both makes the label INJECTIVE (so `a/b` and `a-b` don't share a ref)
and keeps it a VALID ref segment — git rejects refs with `..`, a leading `.`, or a `.lock`
suffix, so a dotfile (`.gitignore`) or `a..b` path would otherwise fail `update-ref`;
(3) restore refuses a **symlink** path (a single guard in `FileBackup.backupFile`, which every
restore path calls first) so it can't follow a link out of the repo or back up the link
target's bytes; (4) restore creates missing parent directories (so restoring a file whose
folder was removed recreates it) and the CLI rejects an **ambiguous** SHA prefix instead of
silently restoring the newest match; (5) the VM commits its undo handle only after the write
lands, deleting the backup ref if the write fails.

Deferred (unchanged): blame rendering (M5–M8), pickaxe/`-S`/`-G` search, binary PREVIEW
(ADR 0086), cross-file point-in-time restore (recover/reflog, ADR 0033).

## Links

- Builds on the M5–M8 blame/file-history plan (git-backend.md, shell-integration.md), ADR
  0033/0075 (snapshot/backup + `RecoverViewModel` safety pattern), 0086 (binary preview on
  restore), 0072 (plain register).
