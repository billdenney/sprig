---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0058. Transient-flag chips on action buttons — tiered by op stakes

## Context and problem statement

Magit's `transient.el` — the popup keymap system that exposes every git command's flag space as togglable letters — is the most-cited "wish my GUI had this" feature in the competitive review (master plan §13.3-D). It bridges the audience split that destroys most git GUIs: novices want simple buttons, power users want the full CLI's flag space, and most clients pick one and lose the other.

The standard transient-menu translation to a pointer UI is "every action button shows togglable chips for its meaningful flags." In CommitComposer: `Commit [--signoff] [--amend] [--no-verify]`. In ForcePush: `Push [--force-with-lease] [--force-if-includes] [--no-verify] [--tags]`. Toggling a chip updates the command preview in the §0057 Commands panel live, so the user sees what Sprig will run before clicking.

The user-preference question, ratified 2026-05-02, was *what's visible by default*. Always-visible chips are powerful but cluttered for routine operations. The maintainer's directive: **everything modifiable, but users shouldn't need to see all options every time.**

## Decision drivers

- Power users want every flag accessible without menu-diving (the "GUI prefers to the CLI" bridge).
- Novices want clean defaults — a "Commit" button shouldn't intimidate.
- Safety invariants (force-push, no-verify) should be *visible* so users see them, not hidden behind clicks.
- Preserve the Finder/Explorer-first invariant — chips live inside task windows, not in any persistent UI.

## Considered options

1. **Tier by op stakes** (this ADR). Routine ops button-only by default with `Options…` disclosure; destructive ops always show chips including locked-on safety chips. User preference toggle to also show chips on routine ops.
2. Discoverable but hidden everywhere — every button defaults to button-only with `Options…`. Cleanest default look; loses the "see safety chips on force-push" visibility.
3. Show non-default chips only — chips appear when a flag is in non-default state. Smarter but harder to predict; more state to track.
4. Always show chips on every action — Magit-style maximal discoverability. Power users love it; novice-cluttering risk.

## Decision

**Option 1 (tier by op stakes).** Action buttons are split into two tiers based on the destructiveness ordering already used in ADR 0033's confirmation tiers:

### Tier A — routine ops (button-only by default)

- `Commit`, `Pull`, `Fetch`, `Push` (non-force), `Switch Branch` (clean tree), `Stash`, `Tag`, `Cherry-Pick` (single, non-conflicting).
- Renders as a single primary button. An `Options…` chevron next to the button discloses chips for the operation's flags.
- Toggled chips update the §0057 Commands panel preview live so users see the resulting `git ...` invocation before clicking.

### Tier B — destructive ops (chips always visible)

- `Force Push`, `Reset --hard`, `Rebase` (interactive or otherwise), `Merge --no-ff` after a divergence, `Submodule Deinit`, `Branch Delete` (unmerged), `Stash Drop`, `Cherry-Pick --abort` mid-conflict, `Revert` (merge commits).
- Locked-on safety chips render alongside the action button — e.g., the Force Push button always shows `[--force-with-lease] [--force-if-includes]` chips with a small lock icon indicating they cannot be turned off (per ADR 0052 / invariant 7 in CLAUDE.md). Optional flags (`--no-verify`, `--tags`, `--atomic`) render alongside as togglable.
- The visible chips serve the audit purpose: the user *sees* the safety invariants apply.

### User preference

A `Preferences → Power Features → "Show flag chips on routine actions"` toggle exists. When enabled, Tier A actions render in Tier B style (chips always visible). Default is off; power users who prefer Magit-style can flip it on.

### Implementation home

- `TaskWindowKit` provides an `ActionButton` primitive that takes a list of `ActionFlag` values and a tier (`.routine` or `.destructive`). Per-flag rendering, lock-state, and the `Options…` disclosure live there.
- Each task window declares its action's flags; e.g., `CommitComposer` declares `[.signoff, .amend, .noVerify]`.
- Toggling a chip publishes a notification through `TaskWindowKit` that the §0057 Commands panel observes and re-renders its preview.

### Confirmation gating for high-stakes flags

`--no-verify` (skip pre-commit / pre-push hooks) gets a one-time-per-session confirmation when first toggled on: "Skipping hooks bypasses your team's pre-commit checks. Continue?" Subsequent toggles in the same session skip the confirmation. This applies in both tiers.

## Consequences

**Positive**
- Resolves the novice/power-user audience split without splitting the UI.
- Force-push safety becomes visible (chips always on) — pairs with §0057's Commands panel for full audit.
- Preserves the invariant: chips live inside task windows, no persistent UI.
- Power-user opt-in is a single toggle, not a separate "expert mode."

**Negative / trade-offs**
- Tier classification of every action is a design responsibility — review needed when new task windows are added. Tracked in `docs/architecture/shell-integration.md` (shell-integration design doc) where the action catalog lives.
- The `ActionButton` primitive needs a11y treatment for chip toggles: VoiceOver reads chip state and lock-state correctly.
- Lock icons on safety chips need contrast in dark mode and Reduce Transparency conditions.
- Localization burden: every flag's chip label needs an `.xcstrings` entry.

## Links

- Master plan §13.3-D.
- Related ADRs: 0033 (destructive-op tiers), 0052 (force-with-lease only), 0057 (Commands panel — chips drive the preview), 0042 (a11y).
- Magit `transient.el` reference: <https://magit.vc/manual/transient/>
