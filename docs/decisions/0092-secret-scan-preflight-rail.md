---
status: proposed
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0092. Secret-scan pre-flight rail — promote the gitleaks-style scan into the rail family, default-on, resequenced earlier

## Context and problem statement

A gitleaks-style pre-commit secret scan is already planned, but parked at M6
(`docs/architecture/security.md` threat #5; `docs/research/git-best-practices.md` §11.11).
Accidentally committing an API key, `.env`, or private key is among the highest-severity
footguns for **both** novices and experts, and the cost of catching it at commit time is
low. The backup engine already excludes likely secrets via `GitCore.JunkFilePatterns` (ADR
0075 amendment) — the staged-commit path deserves the same protection, sooner, and as a
first-class rail rather than a late milestone item.

## Decision drivers

- High severity, both personas; cheap to evaluate at verb time.
- Reuse the existing rail infrastructure (ADR 0070) and the existing junk/secret patterns.
- Detect-and-use over bundle (consistent with ADR 0029/0047).

## Considered options

1. **A default-on `stagedSecretDetected` rail in the ADR 0070 family, resequenced from M6** (this ADR).
2. Keep it at M6 as a standalone scanner — leaves a high-severity gap open longer for no
   infrastructure saving (the rail framework already exists).
3. A blocking pre-commit hook — wrong layer (hooks are the user's, ADR 0050) and blocks rather
   than warns, which trains users to disable it.

## Decision

**Add `GitCore.SecretScan` (a vendored gitleaks-style ruleset — regex + entropy — over the
staged hunks; or detect-and-use the `gitleaks` binary if on PATH, à la the LFS detect flow)
and a default-on `stagedSecretDetected` rail (railID `staged-secret`) in `PreflightChecks`,
wired into `CommitComposerViewModel`.** Warn-and-proceed like every rail (never block);
the banner names the matched file + rule and offers two remedies: "Add to `.gitignore`"
(reuse `GitignoreSuggestion`) and a **revocation-first** note (if it was already committed
upstream, rotating the secret matters more than removing it).

False-positive handling without disabling the rail: a per-finding allowlist (a checked-in
`.sprig/secret-allow` or git-config entry) suppresses known-safe matches; per-rail suppression
(`AppPreferences.suppressedGuardRails`) remains available but is the blunt instrument.

This rail also seeds the push-time secret check (ADR 0093, scanning outgoing commits, not just
staged) and pairs with the future "remove file from history" wizard (revocation-first,
security.md) — that wizard remains a separate item.

## Consequences

**Positive**
- Closes a top-severity footgun early, reusing the rail framework; one dismissal cost for experts.

**Negative / trade-offs**
- Secret scanning is inherently noisy; the allowlist and clear copy are load-bearing for trust.
- Vendored ruleset is a maintenance item (refresh against upstream gitleaks rules periodically).

## Links

- Extends ADR 0070 (rail family + suppression), 0075 amendment (`JunkFilePatterns` deny-list),
  0050 (why a rail, not a hook). Promotes `docs/architecture/security.md` #5 and
  `docs/research/git-best-practices.md` §11.11 from M6. Feeds ADR 0093 (push-time secret rail).
