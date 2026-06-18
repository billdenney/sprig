---
status: proposed
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0086. Binary and visual diff/merge — images, PDF, Office, notebooks, CSV, plus a binary-conflict path

## Context and problem statement

`DiffViewerViewModel` and `MergeConflictResolverViewModel` are text/3-way only (ADR 0027,
0028). For the "git as shared storage" persona (and for data-heavy repos generally), the
common artifacts are *not* text: images, PDFs, Office documents, Jupyter notebooks, and
CSV/tabular data. Today a changed `.png` renders as "Binary files differ" and a conflicting
`.docx` collapses to a whole-file keep-mine/keep-theirs with no preview. This is the single
largest gap for non-developer users and for anyone reviewing figures or datasets.

## Decision drivers

- The storage persona edits binaries far more than code.
- Defer-to-git (ADR 0023): honor user-configured `diff=`/`merge=` drivers and `.gitattributes`.
- Many binaries are LFS pointers (ADR 0029) — preview must resolve the pointer to the blob.

## Considered options

1. **Content-type routing in the existing viewers with built-in renderers + driver/external-tool delegation** (this ADR).
2. Delegate everything to external tools only — loses the in-app, Finder-first experience for the most common case.
3. Bundle heavy converters (LibreOffice headless, nbdime) — violates the detect-don't-bundle stance (cf. ADR 0029/0047); ships a large dependency.

## Decision

**`DiffViewerViewModel` gains content-type detection and routes to a renderer; the resolver
gains a binary-conflict mode.** All git access stays in `GitCore`; renderers/preview are
portable view-model state (Tier 1) with shell-side rendering surfaces (Tier 3).

- **Detection.** `GitCore` exposes the binary marker from `git diff --numstat` (the `-`/`-`
  rows), reads `.gitattributes` `diff=`/`merge=` drivers via `check-attr`, and sniffs
  content type from the blob header for untracked/driverless cases. LFS pointers are resolved
  through the existing LFS hand-off before preview.
- **Renderers (per type, best-effort, degrade gracefully):** image (side-by-side, plus
  swipe/onion-skin overlay), PDF (page-by-page raster compare), Jupyter notebook (cell-level
  diff — detect and use a configured `nbdiff`/driver if present, else fall back to a
  structural JSON-cell diff), CSV/tabular (column-aware row diff), Office documents
  (best-effort text/metadata extraction; otherwise offer the ADR 0027 external-tool
  delegation). Unknown binary → metadata diff (size, mode, type) and the external-tool offer.
- **Binary-conflict mode in `MergeConflictResolverViewModel`.** When git reports a binary or
  driverless conflict, present **keep ours / keep theirs / keep both (rename one)** with the
  same previews instead of hunk text. File-level "accept all mine/theirs" (affordances 3.4).
  Honors any `.gitattributes` `merge=` driver first (defer-to-git).
- **No bundled converters.** Drivers are detect-and-use; the deterministic fallbacks above
  ship in-tree so the feature is never empty-handed.

Deferred (documented, not designed here): three-way *visual* merge for images (beyond
keep-ours/theirs), and a registry UI for user-defined per-type renderers.

## Consequences

**Positive**
- The storage persona can actually see and resolve changes to their real files.
- Reviewing figures/datasets becomes first-class — directly useful in data/clinical repos.

**Negative / trade-offs**
- Snapshot-test surface grows substantially (every renderer needs golden fixtures under
  `tests/snapshots/`); rendering is the riskiest area for cross-platform pixel drift.
- Office/notebook coverage is best-effort without external drivers; copy must set expectations.

## Links

- Extends ADR 0027 (merge UI), 0028 (suggest-only hunk preview — its binary analogue).
- ADR 0023 (shell-out / defer-to-git drivers), 0029 (LFS pointer resolution for previews),
  0019 (reveal level), affordances 3.4 (conflict wording). Snapshot suite: `tests/snapshots/`.
