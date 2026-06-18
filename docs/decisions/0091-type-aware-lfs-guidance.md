---
status: proposed
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0091. Type-aware LFS guidance — extend the large-file rail to binary types and document-store repos

## Context and problem statement

The pre-flight LFS rail (`largeStagedFileWithoutLFS`, ADR 0070) fires only on size (> 50 MiB),
and LFS tracking is detected on `.gitattributes` (ADR 0029). But many problematic binaries are
small-to-medium (`.psd`, `.docx`, `.zip`, short `.mp4`) yet still bloat history and merge
badly. The storage persona in particular accumulates exactly these. Guidance should key on
*type*, not just size, and should recognize a repo that is effectively a document store.

## Decision

**Extend ADR 0070's rail family with a sibling type rail, and add a one-time repo-level
document-store offer.** Both reuse `LFSKit.LFSAttributeChecker`; both are suggest-only and
suppressible like every rail.

- **`binaryTypeWithoutLFS`** (railID `binary-type-without-lfs`): a staged file whose
  extension/sniffed type is in a curated binary set (`.psd .ai .sketch .zip .7z .rar .iso
  .mp4 .mov .wav .flac .docx .xlsx .pptx .pdf .dmg .bin …`, injectable) and not already
  LFS-tracked — regardless of size. Remedy = ADR 0029's "Track with LFS" for that pattern.
- **`DocumentStoreHeuristic`**: when a repo's tracked set is dominated by curated binary
  types, offer once — "This looks like a document store — set up LFS tracking for common
  binary types?" — applying a starter `.gitattributes` LFS pattern set on consent. Quiet
  thereafter (a railID-style one-time flag); never automatic.

Cheap-by-default like the rest of 0070: the type check is a read of the porcelain paths Sprig
already has; the heuristic samples the tracked set, it does not walk full history.

## Consequences

**Positive**
- Removes the small-but-binary footgun before it enters history; serves the storage persona.

**Negative / trade-offs**
- A curated extension list is a maintenance item (audit periodically, like the defaults bundle).
- LFS still requires `git-lfs` on PATH (ADR 0029 detect-and-prompt; never silent install).

## Links

- Extends ADR 0070 (pre-flight rail family + per-rail suppression), 0029 (LFS detect/track
  flow), 0026 (defaults). Reuses `LFSKit.LFSAttributeChecker`.
