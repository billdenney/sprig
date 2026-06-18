---
status: accepted
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

## Implementation notes (2026-06-18)

Shipped as `GitCore.SparseCheckout` (cone verbs + safety analysis), `TaskWindowKit
.SelectiveSyncViewModel`, and a `sprigctl sparse {list,set,disable}` CLI face.

**The "lossless" claim is only true for CLEAN folders — so a fail-closed guard is the
load-bearing addition.** Verified empirically against git 2.43, dropping a folder from the
cone:

| Folder state                | `git sparse-checkout set` behavior            | warns? |
| --------------------------- | --------------------------------------------- | ------ |
| clean tracked               | de-materializes cleanly (recoverable on add)  | n/a    |
| modified (unstaged) tracked | **leaves** the folder materialized            | yes    |
| untracked file              | **leaves** the folder materialized            | yes    |
| staged (index) change       | **de-materializes**; worktree file vanishes   | **no** |

So the picker's "this folder is now off your computer" promise is silently violated for
modified/untracked folders, and a staged edit disappears with no warning. `planChange(to:)`
detects dropped folders holding uncommitted/untracked/staged work (`blockedDrops`) and the
surfaces **fail closed**: skip + report, then offer a snapshot-then-force escape hatch
(matching the submodule-drift decision pattern).

**Force path + recoverability.** Forcing mints an ADR 0075 `WorktreeBackup` FIRST — it
captures tracked changes AND untracked files (throwaway index: `read-tree HEAD` → `add -A`
→ `write-tree` → `commit-tree`, ref under `refs/sprig/backup/`) — then
`forciblyClearDirectories()` runs `git restore --worktree --staged -- <dir>` + `git clean
-fd -- <dir>` (no `-x`, so ignored files are preserved; no `-ff`, so nested repos aren't
removed) and finally `sparse-checkout set`. The removed work is restorable from the Recover
surface; `SelectiveSyncViewModelTests.forceRemovalRoundTrips` proves byte-exact restoration
(the undo-round-trip rule). **No SafetyKit snapshot ref or `DestructiveOpTier` entry is
added** — sparse-checkout never moves HEAD, so the recoverable state is the uncommitted
working tree (a `WorktreeBackup`), not a commit snapshot.

**Submodule + case-insensitive FS care (the ADR's flagged trade-offs), hardened in
adversarial review.** Top-level candidates come from `ls-tree` parsing that keeps only
`tree` entries, so submodule gitlinks (type `commit`) and repo-root files are excluded from
the picker — sidestepping the sparse-vs-submodule hazard. Three review findings were fixed
before merge: (1) a repo with sparse-checkout on but *not* in cone mode (`core.sparseCheckoutCone
≠ true`, i.e. hand-crafted patterns) now reports `SparseSelection.unsupportedPatternMode` and
both surfaces refuse rather than parsing patterns as folder names or `set`ting over the
pattern file; (2) on a case-insensitive repo (`core.ignorecase`), `currentSelection()`
canonicalizes the cone's directory names to the HEAD-tree casing so the picker's checkboxes
line up; (3) `planChange(to:)` folds casing when matching `git status` paths (which carry the
on-disk dirent casing — e.g. after a case-only folder rename) against the dropped set, so the
dirty-folder guard can't be bypassed into a silent de-materialization. Plain-language copy
lives in `TaskWindowVocabulary` (the dependency arrow is UIKitShared → TaskWindowKit, so the
VM can't reach `StatusVocabulary`; the strings are register-neutral plain imperatives).

Still deferred: per-file (non-cone) selection, disk-savings readouts, download-on-demand for
partial-clone blobs, and editing non-cone pattern repos (intentionally refused in this UI).

## Links

- Builds on ADR 0026 / 0049 (Scalar defaults: sparse-checkout + partial clone enabled),
  0030 (Finder-first surfacing), 0072 (plain-language register), 0075 (WorktreeBackup —
  the force path's recovery substrate). Glossary: cone mode, partial clone.
