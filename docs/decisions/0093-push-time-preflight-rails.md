---
status: proposed
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0093. Push-time pre-flight rails — protected-branch, force-push consequence, and secret-in-push

## Context and problem statement

ADR 0070 explicitly defers push-time rails ("Push-time rails remain deferred"). But push is
where several high-value warnings actually belong: pushing to a protected/default branch,
the consequences of a force (even the safe `--force-with-lease --force-if-includes` that ADR
0052 mandates rewrites shared history), and secrets that were committed earlier and are about
to leave the machine. This completes the rail family on the publish boundary.

## Decision

**Add the deferred push-time rail set to the ADR 0070 family, evaluated in the push / Sync
verbs (the `SyncViewModel` push path and the standalone Push verb).** Warn-and-proceed, with
railIDs and per-rail suppression like all rails:

- **`pushingToProtectedBranch`** (railID `pushing-to-protected-branch`): the push target is
  the forge default/protected branch. Heuristic `main`/`master` now; refine via ADR 0063's
  forge metadata when available.
- **`forcePushConsequence`** (railID `force-push-consequence`): the push requires a force.
  Sprig only ever emits `--force-with-lease --force-if-includes` (ADR 0052) and snapshots
  first (ADR 0033); the banner explains *what* gets rewritten and that collaborators on that
  branch may be affected.
- **`secretInOutgoingCommits`** (railID `secret-in-outgoing-commits`): run `GitCore.SecretScan`
  (ADR 0092) across the commit range about to be pushed (`@{u}..HEAD`), not just the staged
  tree — catches secrets committed in an earlier commit. Remedy points at the revocation-first
  guidance.

Cheap-by-default: protected-branch and force are reads of the sync state Sprig already
computes (`SyncOps.branchSyncStates`); the secret scan over outgoing commits runs only on the
push path, on the bounded `@{u}..HEAD` range.

## Consequences

**Positive**
- Closes the warning gap on the publish boundary for both personas; completes the rail family.

**Negative / trade-offs**
- Scanning `@{u}..HEAD` is more work than the staged-only scan; bound it to the push verb and
  the outgoing range (note for impl). Protected-branch is heuristic until ADR 0063 lands.

## Links

- Extends ADR 0070 (the deferred push-time set + suppression), 0052 (force-with-lease
  aliasing), 0033 (snapshot before force), 0071 (Sync verb host), 0092 (secret scan engine),
  0063 (protected-branch refinement). Uses `SyncOps.branchSyncStates`.
