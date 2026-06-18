---
status: accepted
date: 2026-06-10
deciders: maintainer (beginner-affordances directive 2026-06-09), engineering
consulted: —
informed: —
---

# 0070. Pre-flight guard rails — porcelain-driven nudges at verb time

## Context and problem statement

Several classic git accidents are cheap to predict at the moment a verb is invoked: committing
straight to `main` on a shared repo, committing on a detached HEAD (work later "disappears"),
and staging a huge binary that will bounce off the forge's push limit (GitHub hard-fails at
100 MB) or bloat every future clone. Item 2.3 of `docs/research/git-beginner-affordances.md`
(under the 2026-06-09 maintainer directive: easier for git beginners, no AI dependence)
proposes surfacing these as nudges with one-click remedies — at verb time, never as
background nags.

## Decision

**A `PreflightChecks` evaluator in TaskWindowKit produces typed `PreflightWarning` values that
view models surface and shells render as banners.** Warnings never block the verb — `commit()`
proceeds regardless; the banner offers the remedy.

Commit-time rails shipped in this slice (wired into `CommitComposerViewModel.refresh()`):

| Rail | Trigger | One-click remedy (shell-side) |
|---|---|---|
| `committingToDefaultBranch` | HEAD is `main`/`master` **and** has an upstream | "Create a branch here" (carries staged changes) |
| `detachedHEAD` | porcelain `# branch.head (detached)` | "Create a branch at this commit" |
| `largeStagedFileWithoutLFS` | staged file > 50 MiB and `check-attr filter` ≠ `lfs` | ADR 0029's "Track with LFS" flow |

Implementation constraints (all load-bearing):

- **No extra spawns in the common case.** Branch rails are pure reads of the
  `PorcelainV2Status` the view model already parses (the status invocation gains `--branch`);
  the LFS rail stats staged paths first and invokes `git check-attr` (via
  `LFSKit.LFSAttributeChecker`) only for the over-threshold subset — usually empty.
- **Best-effort.** A failing probe drops its rail rather than failing `refresh()`; a genuinely
  broken repo surfaces real errors through the verbs themselves.
- **Heuristic default-branch set** (`main`, `master`), overridable in `PreflightChecks` —
  ADR 0063's forge integration can later substitute the repo's actual default/protected
  branch. The rail stays quiet on default-branch repos with **no upstream** (local-only repos
  shouldn't nag).
- **Threshold injectable** (default 50 MiB — margin under GitHub's 100 MB hard limit); tests
  use tiny thresholds instead of 50 MiB fixtures.
- **Vocabulary** follows the progressive-disclosure register (affordances 2.1): plain-language
  banner first, git term in parentheses.

Deferred (documented, not designed here): the switch-away-with-unpushed-commits informational
(BranchSwitcher already has ahead/behind data via SyncOps when it needs it), push-time rails,
and Preferences toggles for individual rails (ADR 0019's reveal level is the likely home).

## Considered options

1. **Typed warnings from porcelain the VM already has** (this ADR).
2. Git hooks (`pre-commit`) writing the warnings — wrong layer: hooks are the *user's*
   extension point (ADR 0050 trust model), fire too late for banner UX, and can't offer
   one-click remedies.
3. Blocking dialogs instead of banners — guard rails that block become guard rails users
   disable; warn-and-proceed preserves trust and ADR 0040's keyboard-first flow.
4. Background scanning for rail conditions — violates the "at verb time, no nags" principle
   and ADR 0021's idle-CPU budget.

## Consequences

- Beginners get told *before* the mistake, with the fix attached; expert cost is one dismissal.
- `CommitComposerViewModel` exposes `preflightWarnings: [PreflightWarning]`; macOS/Windows
  shells render them (M2/M3 shell work; engine ships now).
- TaskWindowKit gains an `LFSKit` dependency (Tier-1 → Tier-1, ADR 0048-clean) for
  `LFSAttributeChecker` reuse instead of duplicating `check-attr` parsing.
- The worktree size is a proxy for the staged blob's size; the rare stage-then-truncate
  divergence costs a spurious/missed warning, not correctness.

## Amendment — the switch-time rail (2026-06-11, the deferred 2.3 remainder)

`switchingAwayFromUnpushed` (railID `switching-away-from-unpushed`, suppressible like every
rail): shown by the BranchSwitcher when the branch the user is STANDING ON is ahead of its
upstream. Purely informational — the commits stay safely on the branch — but beginners often
read "switched away" as "lost"; the line says they're safe and the remedy is one push. Pure
read of the `branchSyncStates()` pass; quiet with no upstream (nothing to be "not on") and
on a gone upstream (the ADR 0073 cleanup banner owns that story). Push-time rails remain
deferred.

## Amendment — per-rail opt-out + .gitignore suggestion (maintainer-ratified 2026-06-11)

**Per-rail "never show this again."** The maintainer ratified keeping the default-branch
rail's simple heuristic *with a user opt-out as part of the warning banner itself*. Each
`PreflightWarning` now carries a stable `railID` string (`committing-to-default-branch`,
`detached-head`, `large-staged-file-without-lfs`); the banner's checkbox writes the ID into
`AppPreferences.suppressedGuardRails`, and shells pass that into
`PreflightChecks(suppressedRails:)`, which filters the rail out (the LFS rail skips its stat
pass entirely when suppressed). The IDs are wire values persisted in preference files —
renaming one is a migration. Re-enabling lives in Preferences (clear the list); the banner
checkbox is deliberately one-way so a mis-click can't silently disarm a rail forever without
a visible settings entry.

**`.gitignore` suggestion (suggest-only, never automatic).** When untracked files match the
curated junk rules (`GitCore.JunkFilePatterns` — likely secrets, tool temporaries),
`GitignoreSuggestion.detect` produces banner-ready suggestions with the matched paths as
evidence; `append` (the consent action behind the button) adds the patterns to the repo-root
`.gitignore` — creating it if missing, appending under a one-time `# Added by Sprig` header,
never rewriting existing content, deduplicating lines already present. Works for new and
existing repos alike. This pairs with the ADR 0075 backup deny-list: a file the backup engine
deliberately skips is exactly a file the user should hear about once, with a one-click
durable fix.

## Amendment — staged-secret rail (ADR 0092, 2026-06-18)

The commit-time rail set gains a default-on `stagedSecretDetected` rail (railID
`staged-secret`), promoted from M6 (`security.md` #5 / `git-best-practices.md` §11.11). It runs
`GitCore.SecretScan` (a vendored regex + entropy ruleset; no bundled binary) over the staged
hunks and warns — never blocks — when an added line looks like an API key, token, or private
key, naming the file + line + rule and offering two remedies: add the file to `.gitignore`
(reuse `GitignoreSuggestion`) and a revocation-first reminder (rotate if it already reached a
remote). False positives are handled without disabling the rail via a per-finding allowlist
(`.sprig/secret-allow`, entries `<matched-value>` or `<path>:<ruleID>`); per-rail suppression
(`suppressedGuardRails`) remains the blunt instrument. The check is gated on there being staged
paths, so it adds no git spawn in the common "nothing staged" case. The same engine seeds the
push-time secret rail (ADR 0093, scanning `@{u}..HEAD`). Full rationale in ADR 0092.

## Links

- Implements `docs/research/git-beginner-affordances.md` item 2.3 (commit-time set).
- ADR 0019 (reveal levels), 0029 (LFS install/track flow), 0040 (keyboard-first), 0050 (hook
  trust — why rails aren't hooks), 0063 (forge default-branch refinement), 0069 (sibling
  affordance; same directive), 0075 amendment (backup deny-list pairing).
