---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0057. "Commands" panel — default-on, in every task window

## Context and problem statement

Sprig shells out to system `git` for every operation (ADR 0023). That decision is correct (LFS, hooks, signing, custom protocols all "just work"; we're not maintaining a parallel git implementation), but its safety story is invisible to users by default — the literal `git ...` invocation Sprig issues lives only in agent logs.

Two specific consequences make the invisibility costly:

1. **The force-push safety invariant is unauditable to users.** ADR 0033 + ADR 0052 specify that every force-push is `git push --force-with-lease --force-if-includes` — never raw `--force`. Without surfacing this, users have to take Sprig's word for it. Tower's 2025 GPG-CPU bug and SourceTree's silent submodule cascades both demonstrate that "trust me, the GUI is doing the right thing" doesn't survive the first incident.
2. **Sprig's debuggability in the field collapses to log-spelunking.** When a user reports "the merge produced wrong history," reproducing requires extracting the agent's command log from a diagnostic bundle. Surface the commands and the user can copy-paste them into the bug report.

The Sublime Merge competitive-review finding (master plan §13.3-B) cites this pattern as the highest-ROI UX win in the survey: implementation cost is small, trust impact is large, and it pairs naturally with Sprig's "defer to git" stance.

## Decision drivers

- Make Sprig's safety invariants user-visible, not just code-enforced.
- Preserve the Finder/Explorer-first invariant — no main-window changes; this lives inside task windows.
- Cheap to implement, cheap to maintain.
- Default-on (not behind a Preferences toggle) because the trust signal only works for users who don't know to look.

## Considered options

1. **Default-on, every task window** (this ADR).
2. Opt-in via Preferences toggle. Loses the trust-signal-by-default benefit; most users never flip it on.
3. Only on destructive-op task windows (force-push, rebase, merge, reset). Narrower scope but loses the "Sprig is consistent" message.
4. Skip — keep commands in agent logs only, accessible via `sprigctl logs`. Cheapest to ship; matches the Tower/Fork/GitHub-Desktop default.

## Decision

**Option 1 (default-on, every task window).** Every Sprig task window has a collapsible "Commands" panel docked at the footer. The panel renders, in order, every `git ...` invocation Sprig issued during the task window's lifetime: literal argv, exit code, wall-clock duration, and (for failures) the captured stderr.

### Concrete UI

- **Collapsed by default**, single-line summary: `5 commands (3.2s, all succeeded)`. Click to expand.
- **Expanded**: monospace list, one command per row. Each row shows `git <args>` (left), exit code badge (right), duration in ms.
- **Per-row "copy" affordance**: copies the literal argv to the clipboard, ready to paste into a terminal.
- **Failed commands show stderr inline** (truncated at 1000 chars; "Show full" expands).
- **Live-updates** as the task window issues commands. The panel feeds from an `IPCSchema` event stream so streaming-output commands (e.g., `git fetch --progress`) render incremental progress in their row.

### Implementation home

- The renderer is a primitive in `TaskWindowKit` (Tier-1, view-model only) consumed by every macOS / Windows task window.
- The data source is a `RunnerLog` actor in `GitCore`. Every `Runner.run` invocation appends a `LoggedCommand` (argv, started-at, finished-at, exit, stderr-tail) to the log. The agent exposes the log over IPC via a new `IPCSchema.AgentEvent.commandRan` envelope kind so task windows can subscribe to live updates.
- `LoggedCommand` is a Codable, Sendable struct in `GitCore` — portable across all three OSes.

## Consequences

**Positive**
- Force-push safety invariant becomes auditable: the user *sees* `--force-with-lease --force-if-includes` every time. The CI gate (master plan §13.7) verifies the panel contains exactly that string after a force-push.
- Field debuggability: bug reports can include exact commands.
- Cheap to ship, cheap to maintain.
- Pairs with ADR 0058 (transient-flag chips) — chip toggled → command preview updates → user clicks confidently.

**Negative / trade-offs**
- Some UI real estate cost in every task window. Collapsing by default mitigates.
- The `RunnerLog` actor adds a small allocation per command. At Sprig's command-rate (≤10/sec at peak) this is negligible; benchmark gates (ADR 0021) catch regressions.
- A live `commandRan` event stream is one more IPC kind; backward-compatible by ADR 0048 envelope-versioning rules.
- Hooks output potentially long (formatters running over many files). Truncation policy must be predictable; users can `sprigctl logs <repo>` for the full transcript.

## Links

- Master plan §13.3-B.
- CLAUDE.md — invariant 5 (all git invocation through `GitCore.Runner` or `GitCore.CatFileBatch`) makes this implementation-level enforceable.
- Related ADRs: 0023 (defer to git), 0033 + 0052 (force-with-lease invariant), 0058 (transient-flag chips paired UX), 0048 (IPC envelope schema).
