---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0059. FinderSync resilience — heartbeat, `sprigctl finder` CLI, iCloud Drive guards

## Context and problem statement

Sprig's macOS UX depends on the FinderSync extension. The competitive review (master plan §13.3-H, §13.5) shows this surface is fragile in patterns Apple does not always treat as bugs:

- **macOS 15.0 (Sequoia, Oct 2024) removed the FinderSync settings UI** from System Settings. New GitFinder/SnailGit installs were unenable-able for ~3 months until 15.2 reintroduced it. Apple acknowledged the regression but didn't backport the fix to 15.0/15.1.
- **iCloud Drive paths break the extension.** Repos under `~/Library/Mobile Documents/com~apple~CloudDocs/...` produce no FinderSync callbacks. This is an unfixed Apple limitation and applies to every FinderSync-based tool, not just Sprig's competitors.
- **"Waiting forever" after sleep/wake.** Both GitFinder and SnailGit reviewers report extensions that go dark after a sleep/wake cycle until the user toggles the System Settings entry off and on. The IPC channel (XPC) typically survives, but the extension's internal state machine sometimes doesn't.
- **Post-update extension de-registration.** macOS feature updates (e.g., 14.x → 15.x) periodically silently disable third-party FinderSync extensions; users discover this when overlays disappear.

These are field realities, not theoretical risks. Sprig must ship with affordances that detect, surface, and recover from them — not by waiting for users to file bug reports.

## Decision drivers

- Sprig's flagship UX is FinderSync; if it's down, the app is effectively broken.
- Recovery affordances must be discoverable *before* failures happen (so users know what to do when symptoms appear).
- A CLI fallback unblocks users when System Settings can't.
- Failure modes must be detectable from inside the extension and surfaceable to users without the user opening any specific app.

## Considered options

1. **Heartbeat + CLI fallback + iCloud Drive detection** (this ADR — three of the four originally proposed items).
2. Heartbeat alone — detect failure but no recovery affordance.
3. CLI alone — recovery only, no detection.
4. Skip — match GitFinder/SnailGit's behavior; let users discover failures.

A fourth originally-proposed item (sleep/wake integration test on a self-hosted macOS runner) was deferred until that runner is provisioned; tracked in `docs/planning/risk-register.md` as a follow-up.

## Decision

**Option 1 — three coordinated mechanisms:**

### 1. Heartbeat health-check

The `SprigFinder` FinderSync extension XPC-pings `SprigAgent` every **5 seconds**. If it gets no reply for **30 seconds** (six consecutive missed pings):

- The extension posts a Notification Center alert: **"Sprig is not responding — Reload extension?"** with action buttons `Reload` (relaunches the extension via `pluginkit -e use -i com.sprig.finder`) and `Open Sprig Status…` (opens the Status task window for diagnostics).
- The extension internally marks itself "degraded" and stops issuing badge requests until reconnection succeeds. This prevents accumulating XPC errors in `Console.app`.
- On reconnection (heartbeat reply received), the alert is automatically dismissed and the extension issues a full re-query of its visible Finder windows so badges re-populate.

The heartbeat IPC adds two new envelope kinds to `IPCSchema`: `ClientRequest.heartbeatPing` and `AgentResponse.heartbeatAck`. Both Sendable, Codable; backward-compatible with existing receivers per ADR 0048's envelope-versioning rules.

### 2. `sprigctl finder` CLI fallback

The `sprigctl` CLI gains a `finder` subcommand:

```
sprigctl finder enable     # enables the FinderSync extension via pluginkit -e use
sprigctl finder disable    # disables it via pluginkit -e ignore
sprigctl finder status     # prints current state: enabled/disabled, agent reachable, heartbeat age
sprigctl finder reload     # disable + enable in sequence to reset extension state
```

This works regardless of System Settings UI availability — the macOS 15.0 incident would have been transparent to Sprig users with a working terminal.

`finder` runs only on macOS; on Linux/Windows builds the subcommand is registered with a stub that prints "FinderSync is macOS-only; use `sprigctl shell-extension` on Windows." (The Windows analogue ships under ADR 0060.)

### 3. iCloud Drive path detection + one-time toast

On the first time the FinderSync extension issues `requestBadgeIdentifier(for:)` for a path matching `~/Library/Mobile Documents/com~apple~CloudDocs/...` (or any other iCloud Drive subpath), the agent posts a one-time-per-user Notification Center toast:

> **Sprig overlays unavailable on iCloud Drive paths**
> Apple's FinderSync API does not deliver events inside iCloud Drive. Overlay icons won't render here, but git status remains visible in the **Sprig Status** task window (right-click → Sprig ▶ → Status…).
> [ Show me Status ] [ Don't show again ]

The "don't show again" preference is per-user (stored in `~/Library/Application Support/Sprig/Preferences.plist`) and survives upgrades. The detection itself is cheap: the agent checks the path prefix on every request and short-circuits before issuing any git work, so iCloud paths consume <1 ms each.

For future Apple API changes, the detection is parameterized by a small list of "blocked path prefix" entries in agent config; extending it later (e.g., for new system-protected directories) doesn't require a code change.

## Consequences

**Positive**
- Sprig recovers from the three most-reported FinderSync failure modes without user intervention or app-update.
- A user locked out by a future System-Settings regression has a one-line CLI recovery path documented in the Help menu.
- iCloud Drive paths fail gracefully with explicit user guidance, not silent missing badges.
- Heartbeat machinery doubles as agent-health diagnostic surfaceable in `sprigctl status`.

**Negative / trade-offs**
- 5s heartbeat × 1 ping × empty reply ≈ negligible per-tick cost; verified in benchmarks before shipping.
- The iCloud toast can feel alarmist on first encounter; "don't show again" is essential.
- `sprigctl finder` requires the user have shell access — corporate-managed Macs sometimes don't. Document the manual `pluginkit` fallback in `docs/architecture/shell-integration.md`.
- Adding heartbeat IPC envelopes means receiver code must dispatch them; the existing dispatch loop (per `docs/architecture/overview.md`) handles unknown kinds gracefully via `IPCError.unknownMessageKind` so older agents don't fault.

## Links

- Master plan §13.3-H, §13.5.
- Related ADRs: 0030 (Finder-first architecture), 0034 (no menu-bar helper), 0048 (IPC envelope schema), 0042 (a11y for the toast / alert text), 0060 (Windows shell hardening — analogous resilience).
- Apple Developer Forums thread 756711 (FinderSync 15.0 regression).
- Michael Tsai blog: <https://mjtsai.com/blog/2024/10/03/finder-sync-extensions-removed-from-system-settings-in-sequoia/>
