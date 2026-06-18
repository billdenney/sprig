---
status: proposed
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0089. Selective sync — a beginner-facing folder picker over sparse-checkout cone mode

## Context and problem statement

The Scalar defaults bundle (ADR 0026/0049) already enables the machinery for sparse-checkout
cone mode and partial clone, and `sparse-checkout` is listed as a power-user verb. But there
is no beginner-facing UI for it. "Choose which folders to keep on this computer" is exactly
the SharePoint/OneDrive *selective sync* feature — a strong, familiar mapping for the storage
persona that costs little because the engine work is largely done.

## Decision drivers

- Direct analogue to a feature non-developers already understand (selective sync).
- The underlying machinery exists; only the framing/UI is missing.
- Must be lossless and reassuring: sparse-checkout changes worktree *materialization*, never
  committed history.

## Considered options

1. **Cone-mode folder picker (`GitCore.SparseCheckout` + `SelectiveSyncViewModel`)** (this ADR).
2. Expose raw sparse-checkout patterns to beginners — too sharp; pattern mistakes hide files.
3. Nothing; leave it as a CLI-only power-user verb — abandons the storage-persona win.

## Decision

**Add `GitCore.SparseCheckout` (wrapping `git sparse-checkout init --cone` / `set` / `add` /
`disable` and reading current cone patterns) and a `SelectiveSyncViewModel` (TaskWindowKit),
surfaced from a repo-root right-click as "Choose folders to keep on this Mac…".** The window
shows the repo's top-level directory tree with checkboxes; toggling updates the cone set.
Cone mode only for this UI (power users keep the CLI for arbitrary patterns). Works
alongside the partial-clone filter already in the Scalar bundle.

Copy uses the plain register (`StatusVocabulary`) and states the safety property explicitly:
unchecked folders are *removed from this computer's working copy only* — nothing is deleted
from history and they return on re-check. Disabling selective sync restores the full worktree.

Deferred: per-file (non-cone) selection, size/disk-savings readouts, and a "download on
demand" interaction for partial-clone blobs.

## Consequences

**Positive**
- The storage persona gets a recognizable, low-risk way to manage large repos on disk.

**Negative / trade-offs**
- Sparse interactions with submodules and case-insensitive filesystems need care (note for
  impl + cross-platform tests); a mis-set cone should fail closed (warn, don't silently hide).

## Links

- Builds on ADR 0026 / 0049 (Scalar defaults: sparse-checkout + partial clone enabled),
  0030 (Finder-first surfacing), 0072 (plain-language register). Glossary: cone mode,
  partial clone.
