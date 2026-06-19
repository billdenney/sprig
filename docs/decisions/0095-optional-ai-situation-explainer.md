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

## Implementation status

**Engine shipped (AIKit); Tier-3 UI + cloud-confirmation deferred (status stays `proposed`).**

- **Engine (AIKit).** The portable explainer is built:
  - A versioned, user-overridable prompt `situation-explainer-v1.md` under
    `AIKit/Prompts/` (per ADR 0037, loaded via the same `PromptLoader.loadBundled`
    path as `commit-message-v1`). It instructs the model to translate a repo
    snapshot into plain language, suggest only verbs from a closed set, lead with a
    parked operation or conflicts, and stay suggest-only (never run raw git).
  - `RepoSituation` — a small, provider-neutral input struct *in AIKit*. AIKit is a
    Tier-1 **leaf** package (no cross-package deps), so it cannot import GitCore's
    `MidstreamOperation` or TaskWindowKit's `RepoStatusSummary`; the caller (a
    TaskWindowKit view model, a follow-up slice) flattens its rich engine types onto
    `RepoSituation` (`ParkedOperation` mirrors `MidstreamOperation`'s cases). This
    keeps AIKit testable in isolation and the prompt input stable.
  - `AISituationExplainer` (actor) renders the prompt + snapshot into an `AIRequest`,
    calls the injected `any AIProvider` (local-first; Ollama is the production
    default, but the engine just takes any provider), and returns a
    `SituationExplanation` (text + structured `SuggestedAction`s + a `.ai`/
    `.deterministic` source tag). On **no provider, an empty completion, or any
    `AIError`** it returns the deterministic explanation — AI never blocks the
    answer (ADR 0007/0036). It also falls back when the model's prose **breaks a
    hard prompt safety rule** — instructing a raw `git` command (the explainer is
    suggest-only) or implying data was lost (Sprig keeps recoverable snapshots) —
    via a runtime guard (`violatesSafetyRules`), the backstop this ADR's "eval
    coverage is needed to keep guidance safe" trade-off calls for. Suggestion chips
    stay deterministic even on the AI path so the UI always has clickable verbs
    mapped to real Sprig affordances.
  - `DeterministicSituationExplainer` — the always-available, no-AI fallback: pure
    template strings over `RepoSituation`, priority-ordered (parked op > conflicts >
    detached HEAD > diverged > behind > ahead > dirty > clean) to agree with the
    prompt's rules.
  - Held-out eval corpus `tests/ai-evals/situation-explainer-v1.json` (per ADR 0038)
    pins repo-situation → expected guidance shape (lead verb, required/absent verbs,
    headline substrings), exercised against the deterministic path with no LLM. Unit
    tests cover the AI path via `MockAIProvider` (canned success, scripted error →
    fallback, empty → fallback, no-provider → fallback) and the deterministic path
    directly.
- **NOT built (explicitly later):** the Tier-3 task-window UI that renders the
  explanation + clickable verb chips, the AI-enabled gate, and the cloud-provider
  per-action "will send repo context to X" confirmation (ADR 0036). The engine never
  bypasses that boundary — it only takes a provider the shell decides to construct.
- **Why the status stays `proposed`:** the ADR is still `proposed` pending maintainer
  ratification, and its full decision spans the cloud-confirmation boundary and the
  user-facing surface, which are unbuilt. The engine half is unambiguous and shipped;
  flip to `accepted` once the maintainer ratifies the full surface.

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
