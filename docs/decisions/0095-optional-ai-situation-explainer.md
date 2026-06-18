---
status: proposed
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0095. Optional AI situation-explainer — a local-first "what should I do now?" guide

## Context and problem statement

ADR 0035 scopes the M7 AI features to merge-conflict suggestions, commit-message drafting, and
PR descriptions. A distinct, high-value use for the novice goal is an *opt-in* "explain my
situation / what should I do now?" guide: when a user is stuck (diverged branch, detached
HEAD, mid-rebase, unexpected conflict), translate the repo state into plain language and
suggest the next safe Sprig verb. This complements — never replaces — the deterministic
plain-language vocabulary (ADR 0072), and stays within the project's "AI is opt-in,
local-first, suggest-only" stance.

## Decision drivers

- Leans into the beginner goal without making any default depend on AI (affordances non-goal).
- Must be suggest-only and never act on its own (ADR 0028 stance).
- Local-first; cloud is BYOK + per-action confirmation (ADR 0036).

## Considered options

1. **A versioned AIKit prompt that explains structured repo state and proposes next verbs, opt-in** (this ADR).
2. Leave explanation entirely to the deterministic vocabulary (ADR 0072) — fine as the
   default, but doesn't help the genuinely-stuck "I don't know what any of this means" user.
3. An agent that *takes* recovery actions — rejected; violates suggest-only and the trust spine.

## Decision

**Extend ADR 0035's M7 scope with an opt-in `AIKit` "situation explainer."** A versioned
prompt (markdown under `AIKit/Prompts/`, per ADR 0037) consumes the structured state Sprig
already has (`RepoStatusSummary` + porcelain + recent reflog) and returns a plain-language
explanation plus one or more **suggested** next actions, each mapped to an existing Sprig verb.
It never executes anything: the user picks a verb, which runs through the normal (snapshotted,
confirmed) path. Gated behind AI being enabled; local providers (Ollama / Apple Foundation
Models) default; cloud providers BYOK with the per-action "will send repo context to X"
confirmation. Held-out eval fixtures (repo-state → expected guidance) go under
`tests/ai-evals/` per ADR 0038.

The deterministic vocabulary (ADR 0072) remains the default explainer for everyone; this is
strictly an optional upgrade for users who have turned AI on.

## Consequences

**Positive**
- Helps the stuck beginner in their own words, consistent with the local-first stance.

**Negative / trade-offs**
- Sending repo state to a model has privacy weight; the local-first default + explicit cloud
  confirmation (ADR 0036) is the mitigation. Eval coverage is needed to keep guidance safe.

## Links

- Extends ADR 0035 (AI feature scope). ADR 0028 (suggest-only), 0036 (local-first privacy),
  0037 (prompt storage), 0038 (eval harness), 0072 (deterministic vocabulary it complements).
  Relates to `AgentKit`.
