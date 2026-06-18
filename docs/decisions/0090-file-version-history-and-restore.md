---
status: proposed
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

## Links

- Builds on the M5–M8 blame/file-history plan (git-backend.md, shell-integration.md), ADR
  0033/0075 (snapshot/backup + `RecoverViewModel` safety pattern), 0086 (binary preview on
  restore), 0072 (plain register).
