---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0062. Stacked-PR UI — right-click verbs + Stack Manager task window (no main-window sidebar; Preferences-disable-able)

## Context and problem statement

ADR 0051 commits to stacked PRs as first-class via `rebase.updateRefs=true`. The competitive review (master plan §13.3-E) identifies stacked PRs as the modern power-user differentiator in 2026 — Graphite, `git-spice`, ghstack, and (most visibly) GitButler all build their UX around it.

The standard implementation pattern is a **persistent sidebar** showing the user's stack — branches grouped, per-PR CI status, drag-to-reorder. That pattern is incompatible with the Finder/Explorer-first invariant (ADRs 0030, 0034): no main-window sidebar, no permanent UI surface.

The design question is therefore: **how does Sprig deliver stacked-PR UX as effective as a sidebar without being a sidebar?**

Additional ratification 2026-05-02: stacked PRs are a power-user feature; some users will never use them and don't want the affordances cluttering their right-click menu. The UI must be opt-out-able via Preferences.

## Decision drivers

- Preserve the Finder/Explorer-first invariant — no persistent main-window or sidebar UI.
- Make stacked PRs first-class for users who use them (default-on for discoverability).
- Don't burden users who never use stacks (Preferences toggle to suppress).
- Minimize the right-click-menu real estate cost (don't add 5 verbs; add 1–2 with submenus when relevant).

## Considered options

1. **Right-click verbs + Stack Manager task window, default-on, Preferences-disable-able** (this ADR).
2. Right-click verbs only — no Stack Manager window. Lighter scope; users wanting a bird's-eye view fall back to `gt log` / GitHub web.
3. Defer stacked PRs past 1.0 entirely — drop ADR 0051 from 1.0 scope.
4. Branches sidebar inside `BranchSwitcher` task window groups stacks; no separate window. Simpler UI surface; harder to find for users who don't open BranchSwitcher first.

## Decision

**Option 1.** Three coordinated surfaces, with a Preferences toggle to suppress the entire feature for users who don't use stacks.

### 1. Right-click verbs (when a stack is detected on the right-clicked branch / repo)

Sprig detects "this branch is part of a stack" by checking whether `rebase.updateRefs` is on, whether multiple branches in the repo have a chain via `branch.<name>.merge` pointing at a non-default-branch upstream, and whether `git config branch.<name>.parent` is set (Sprig's own annotation, written when the user creates a branch off a non-default-branch). If yes:

- **Right-click → Sprig ▶ → Restack…** — runs `git rebase --update-refs <stack-base>` for the current branch, then push-with-leases the whole stack.
- **Right-click → Sprig ▶ → Open Stack…** — opens the Stack Manager task window for the right-clicked repo's stack containing the right-clicked branch.

When no stack is detected, neither verb appears. The "Sprig ▶" submenu stays uncluttered for users who don't use stacks.

### 2. Stack Manager task window

A dedicated task window opened by `Open Stack…` (or by `sprigctl stack <repo>` from the CLI). Contents:

- **Vertical stack rendering**: each branch in the stack as a horizontal row, ordered tip-to-base. Branch name, last commit subject, ahead/behind vs. parent, PR status badge (open/draft/approved/changes-requested/merged), CI status (passing/failing/pending/—).
- **Single primary action**: a "Restack and force-push (with leases)" button that runs `git rebase --update-refs` on every dependent branch, then `git push --force-with-lease --force-if-includes` per branch. Pre-flight shows the resulting branch SHAs and the PR base-branch updates required (some forges allow base-branch updates via API; others need manual PR edit). Post-flight: any PRs whose base branch needs updating get a "Sprig will update PR base?" prompt with one-click apply.
- **Per-branch row affordances**: "Open PR" (if exists), "Create PR" (if not), "Drop from stack" (resets `branch.<name>.parent`), "Switch to this branch."
- **Top-of-window summary line**: "Stack of 4 branches based on `main`. Restack pending: 2 branches behind base."

The window is a single-purpose task window — opens, does its job, closes. Per ADR 0030, no persistent state in the window beyond user-transient edits.

### 3. PR badges in BranchSwitcher

When the user opens `BranchSwitcher`, branches that participate in a stack are visually grouped (indented under their parent). PR status badges render next to each branch (regardless of whether stacked).

### 4. Preferences toggle

A new Preferences task window section: **Power Features → Stacked PRs**.

- Toggle: "Enable stacked-PR support" (default: on).
- When off: the right-click verbs are suppressed (the detection still runs internally because some Sprig commands need to know — e.g., to emit safe `--force-with-lease` instead of accidentally rewriting downstream branches — but the user-facing verbs and Stack Manager become unreachable from the GUI; `sprigctl stack` still works).
- When the user toggles off, no migration is required; the toggle is purely UI-suppression.

The Preferences task window itself is reachable via right-click → Sprig ▶ → Preferences… (per ADR 0034).

### CLI parity

`sprigctl stack <repo>` lists the stack; `sprigctl stack restack <repo>` runs the operation. CLI unaffected by the GUI Preferences toggle — CLI users never see the GUI verbs anyway.

## Consequences

**Positive**
- Stacked PRs become a first-class flagship feature without violating the Finder/Explorer-first invariant.
- Users who never stack get zero clutter once they flip the Preferences off.
- Restack-and-push is a single button — competing tools require chained CLI invocations.
- PR-base-branch update is integrated; competitors leave that step to manual PR edits.

**Negative / trade-offs**
- Stack detection adds per-repo metadata (`branch.<name>.parent` git config keys). Users opening Sprig-tracked stacks in another GUI will see those keys but they're harmless.
- The Stack Manager task window is a new design surface; needs a11y review and a decent empty-state when no stack exists yet.
- Forge API integration for PR-base-branch updates is forge-specific (GitHub supports `PATCH /repos/:owner/:repo/pulls/:n` with `base`; GitLab via `PUT /projects/:id/merge_requests/:iid` with `target_branch`; Bitbucket Cloud doesn't support it cleanly — falls back to manual). Implementation must handle "this forge can't update PR base" gracefully.
- Preferences toggle adds a per-user setting to maintain.

## Links

- Master plan §13.3-E, §13.4 ("persistent status sidebar / dashboard" rejection list).
- Related ADRs: 0030 (Finder/Explorer-first), 0034 (no menu-bar/tray), 0051 (stacked-PR workflow as first-class), 0052 (force-with-lease only — this ADR specifies how restack uses it), 0063 (forge integration as task-window verbs — Stack Manager uses the same forge layer).
- Graphite reference: <https://graphite.dev/docs>
- `git-spice` reference: <https://abhinav.github.io/git-spice/>
