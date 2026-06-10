---
status: accepted
date: 2026-06-10
deciders: maintainer (beginner-affordances directive 2026-06-09), engineering
consulted: —
informed: —
---

# 0074. Template commit messages — the deterministic, non-AI default

## Context and problem statement

Affordances item 2.5: the empty commit-message box is a real freeze point for beginners
("what do I write here?"). Sprig's AI drafting (ADR 0035) answers it for users who opt in —
but per the maintainer's less-AI directive, the never-enable-AI user deserves a working
default too, and teams that already configured `commit.template` deserve to see *their*
template, exactly as terminal `git commit` would show it.

## Decision

**`CommitMessageSuggestion` produces a deterministic seed, two sources in priority order:**

1. **The repo's `commit.template`** (ADR 0023 defer-to-git): config value resolved (including
   git's `~/` expansion and repo-relative paths), file loaded, `#` comment lines stripped the
   way `git commit` strips them; first remaining line → subject, rest → body. Unreadable or
   missing template files fall through (git itself warns-but-proceeds).
2. **Synthesis from the staged paths**, deliberately humble — a seed the user edits, not
   prose pretending to know intent:
   - one file → `Update <name>` — `Add <name>` when every staged path is newly added,
   - one directory → `Update <dir> (N files)`,
   - mixed → `Update N files across M directories`.

**Composer wiring**: `CommitComposerViewModel.suggestMessage()` fills the draft **only when
both subject and body are empty** — it never clobbers user input, and a second call is a
no-op. The Add-vs-Update wording derives from the porcelain index codes the composer already
parses (`A` = newly added; no extra spawns; the template lookup is the only added invocation,
one `git config --get`).

## Considered options

1. **Template-first, path-synthesis fallback** (this ADR).
2. AI-first with template fallback — inverts ADR 0036's local-first/opt-in posture and the
   maintainer's less-AI directive; AI remains the opt-in upgrade layered on the same seed.
3. Conventional-Commits-aware synthesis (`feat(scope): …`) — guessing the type/scope wrong
   teaches the wrong lesson; repos that want CC put it in `commit.template` (which wins), and
   the planned CC prompt (master plan §11.5) is its own VM.
4. No default (status quo) — keeps the freeze point.

## Consequences

- The commit dialog can open pre-seeded everywhere, with team templates honored verbatim.
- The AI drafting feature (ADR 0035) becomes an *upgrade* of a working baseline rather than
  the only escape from an empty box.
- Synthesis quality is bounded by design; the ADR's bar is "a true, editable statement of
  what's staged", nothing more.

## Links

- Implements `docs/research/git-beginner-affordances.md` item 2.5.
- ADR 0023 (defer to git — `commit.template` honored), 0035/0036 (AI drafting stays the
  opt-in upgrade), 0070 (same composer surface).
