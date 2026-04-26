# AI Integration

Sprig's AI features are **optional, opt-in, and local-first by default** (ADR 0007, 0036). This is a brief index against the relevant ADRs and master-plan sections; the substantive design lands during M7 when AI features actually ship. Until then, no AI code exists in `packages/AIKit/` beyond protocol stubs.

ADR cross-references: 0007 (AI is optional and pluggable), 0013 (multi-provider at launch), 0035 (M7 feature set), 0036 (privacy default = local), 0037 (prompts as versioned markdown), 0038 (eval harness gates merges).

## Provider abstraction

`AIKit` is Tier 1 portable. It exposes a `Provider` protocol with four implementations planned for M7:

| Provider | Type | When to default to |
|---|---|---|
| **Anthropic Claude** | cloud, BYOK | User opts in explicitly; first call per session shows "will send code to Anthropic" confirmation |
| **OpenAI** | cloud, BYOK | Same as Anthropic |
| **Ollama** | local, no key | First-run AI setup steers users here. Includes a one-click "install Ollama" flow on macOS / Windows |
| **Apple Foundation Models / MLX** | local, on-device, macOS-only | Default on macOS 15+ when available; falls back to Ollama otherwise |

The protocol is async streaming (`AsyncStream<TokenChunk>`); features that don't need streaming (commit-message suggestion) accumulate before showing.

## M7 features (ADR 0035)

Three features ship with AI at M7:

1. **Merge conflict resolution** (flagship). AI proposes a per-hunk resolution; user sees a unified-diff preview with rationale; "Apply" inserts into the merge view, still editable. "Accept and Next" advances through conflicts. Non-destructive — every AI suggestion is auditable and reversible (ADR 0028).
2. **Commit-message suggestion** in CommitComposer. From the staged diff, draft a Conventional-Commits-style subject + body. User edits before commit.
3. **PR description drafting** after push, when `gh` / `glab` CLI is detected. Drafts a "## Summary / ## Test plan" body from the commit range vs base.

"Explain this diff / commit / file history" is **deferred to post-1.0**. Strong demand signal would re-prioritize.

## Prompts (ADR 0037)

Prompts live in `packages/AIKit/Sources/AIKit/Prompts/*.md` as versioned markdown. Loaded at runtime, so contributors can iterate via PR. Users can override by dropping markdown files into `~/Library/Application Support/Sprig/prompts/` (or the equivalent `PathResolver.appSupport()` location on Windows / Linux).

Each prompt has a small frontmatter:

```yaml
---
id: merge-conflict-resolver
version: 1
provider-overrides:
  ollama-default: prompts/merge-conflict-resolver.ollama.md
---
```

Provider overrides let us tune for smaller local models that don't follow large-context prompts as well.

## Eval harness (ADR 0038)

`tests/ai-evals/` ships with M7. A held-out set of 50–200 real-world merge conflicts with gold-standard human resolutions. Runs on every PR that touches `packages/AIKit/` or any prompt file, against every configured provider.

Metrics:

- **% hunks matching gold** (string-equal or AST-equal)
- **% parse/compile-OK** (the resolution is valid syntax for the file's language)
- **% within token budget**

Regressions block merge. Provider-portable: the same eval runs against Anthropic, OpenAI, Ollama, and Apple Foundation Models, so swapping providers can't silently degrade quality.

## Privacy guardrails (ADR 0036)

- **Local-first default.** First-run AI setup steers to Ollama or Apple Foundation Models.
- **Per-provider per-session confirmation** for cloud providers ("This will send the conflict to Anthropic. Continue?"). User can dismiss permanently per provider; default state is "ask each session."
- **Data-handling matrix** surfaced in AI settings: which providers train on data, what's retained, what's a zero-retention API endpoint, etc. Updated per release.
- **No AI calls without an explicit feature trigger.** AI does not run in the background, does not pre-fetch suggestions, does not "warm the cache" with the user's repo.

## Where to expand

- **M7 PR work** populates this doc with: provider implementation details, prompt structure conventions, eval-harness mechanics, the AI Settings UI layout, and the per-provider data-handling matrix.
- **Pre-M7**: this doc stays a brief index. The protocol stubs in `packages/AIKit/` are intentionally minimal until M7 begins.

## Open questions

- Streaming UI for cloud-provider responses — show tokens as they arrive, or buffer to a complete suggestion? Decision: probably stream for "explain this diff" (post-1.0), buffer for "merge conflict resolution" (M7). Confirm during M7 design.
- BYOK key storage — Keychain entries vs. environment variables? Lean Keychain for usability + `~/.sprig/ai.toml` override for power users / CI.
- Eval corpus licensing — synthesized vs. real-world? Mix: 50% synthesized (no license concerns), 50% from CC0 / Apache repos with explicit consent. Documented in `tests/ai-evals/CORPUS.md` when M7 begins.
