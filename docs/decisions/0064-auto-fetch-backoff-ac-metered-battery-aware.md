---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0064. Auto-fetch — AC / metered / battery-aware backoff

## Context and problem statement

GitKraken's default 60-second `git fetch --all` loop, fired across every open repo tab, is the canonical "Git GUI ate my battery" complaint in the competitive review (master plan §13.3-G, §13.5). Tower partly mitigates by pausing fetch when battery <20%; no surveyed client respects macOS Low Power Mode or Windows metered connections systematically. Most clients also fetch when the system is asleep or display is locked, producing surprise data usage on cellular connections.

Sprig's auto-fetch policy needs to balance three concerns:

- **Freshness**: PR-status badges (per ADR 0063) should be approximately current, not 6-hour-stale.
- **Power and bandwidth**: laptops on battery, machines on cellular tethering, machines under Low Power Mode should fetch less aggressively.
- **Visibility**: when Sprig has consciously paused fetching, the user should be able to see why and override per-repo.

The Finder/Explorer-first invariant (ADRs 0030, 0034) forbids a tray icon or menu-bar countdown indicator. The state must be visible, but it must be visible in the right place — the Status task window.

## Decision drivers

- Sprig is the negative-space differentiator: every other client annoys laptop users; Sprig won't.
- Backoff logic lives in the agent (Tier-2 platform adapters); user-visible state lives in a task window.
- Per-repo override exists for users who genuinely want aggressive fetching on a specific repo.
- No tray, no menu-bar, no Dock-icon countdown — the invariant is non-negotiable.

## Considered options

1. **Backoff in agent + visibility in Sprig Status task window** (this ADR).
2. Backoff only — no GUI surface (state via `sprigctl status`). Simpler; opaque to GUI users.
3. Per-repo Preferences slider (off / 5 min / 15 min / hourly / daily) + the Status surface. Adds Preferences UI; more knobs.
4. Skip the feature; fetch every 5 min unconditionally. Match other clients; accept battery complaints.

## Decision

**Option 1.** Two coordinated layers.

### 1. Agent-side backoff logic

The Sprig agent implements a per-repo `FetchScheduler` actor that decides when to fire `git fetch` for each watched repo. The decision uses these signals (Tier-2 platform adapters supply the platform-specific values):

| Signal | macOS source | Windows source | Linux source (post-1.0) |
|---|---|---|---|
| Power state (AC vs battery) | `IOPSCopyPowerSourcesInfo` | `GetSystemPowerStatus` | `/sys/class/power_supply/AC/online` |
| Network metered? | `NWPathMonitor.isExpensive` | `NetworkInformation.NetworkCostType` | NetworkManager `Metered` |
| Network type (Wi-Fi / cellular / VPN / wired) | `NWPathMonitor.usesInterfaceType` | `NetworkInformation.GetConnectionProfiles` | NetworkManager device class |
| Low Power Mode | `ProcessInfo.processInfo.isLowPowerModeEnabled` | (no equivalent — treat AC + battery >20% as proxy) | (none stable) |
| Display sleep / lid closed | `IORegistryEntryCreateCFProperty(...kIOPMSystemSleepingKey)` | `WTSRegisterSessionNotification` | `loginctl session-status` |
| Sprig app focus | macOS `NSApp.isActive` (forwarded over IPC) | Windows `GetForegroundWindow` | (none — treat as always-focused) |

**Default schedule** (subject to per-repo override):

| Conditions | Fetch interval |
|---|---|
| AC + unmetered + Sprig in focus | 5 minutes |
| AC + unmetered + Sprig backgrounded | 15 minutes |
| AC + metered (any) | 30 minutes |
| Battery + unmetered + battery >50% | 30 minutes |
| Battery <50% (any network) | Pause (no fetch) |
| Display asleep / lid closed | Pause (no fetch) |
| Low Power Mode active | Pause (no fetch) |

The scheduler logs every fetch attempt and every backoff decision via `DiagKit` so `sprigctl status` shows "next fetch in 4:32 (AC + unmetered + focused)" or "fetch paused: lid closed."

### 2. Sprig Status task window — visibility + per-repo override

The Status task window (right-click → Sprig ▶ → Status…) gains an "Auto-fetch" panel per repo:

- **Current state**: "Fetching every 5 min — on AC + unmetered, Sprig focused" / "Paused — display asleep" / "Paused — battery 23%."
- **Last fetch**: "5 min ago, succeeded" / "47 min ago, failed (network unreachable)."
- **Override**: per-repo dropdown — "Default", "Always 5 min", "Always 15 min", "Hourly", "Daily", "Off." Override is persistent in `~/Library/Application Support/Sprig/Preferences.plist` per repo.
- **Force fetch now**: button that invokes `git fetch --all --prune` immediately regardless of backoff state.

**Critically: this UI lives only in the Status task window — opened on demand, closed when done.** No tray, no menu-bar, no Dock badge. Per ADR 0034.

### Edge cases

- **A repo's remote is unreachable** (DNS failure, server 502, etc.): exponential backoff with jitter — 30s, 1m, 2m, 4m, 8m, capped at 30m. Per-repo so one slow remote doesn't stall others.
- **A user starts a foreground task that fetches** (clone, pull, push) while a scheduled fetch is mid-flight: the scheduler defers; the foreground operation owns the fetch.
- **A repo is removed from Sprig's repo list**: scheduler clears its entry. Per ADR 0065, stashes are exported first.
- **Newly-added repos**: fetched once on registration, then enter the schedule.

## Consequences

**Positive**
- Differentiator: Sprig is the only mainstream client that genuinely respects battery and metered networks across both platforms.
- The Status task window is the natural home — discoverable for users who care, invisible to users who don't.
- `sprigctl status` includes the same data — CLI users get parity.
- Schedule is conservative by default; per-repo override unblocks the rare user who wants aggressive fetching.

**Negative / trade-offs**
- Tier-2 platform adapter work for AC/metered/lid-closed/Sprig-focus signals is meaningful — adds to the M2 / M2-Win agent scope.
- Network conditions can change rapidly (Wi-Fi → cellular while the agent is running). Adapters subscribe to OS notifications rather than polling, but state may briefly lag.
- The detection accuracy on Linux (post-1.0) is poorer for some signals (no Low Power Mode equivalent); document in `docs/architecture/cross-platform.md`.
- "Paused" state can confuse users who don't see expected fetch activity; the Status task window's panel is the answer, but they have to open it.

## Links

- Master plan §13.3-G.
- Related ADRs: 0030 (Finder-first), 0034 (no menu-bar/tray), 0048 (Tier-2 platform adapters), 0063 (forge badges depend on fetch frequency), 0034's "Sprig Status task window" surface, 0021 (perf budgets — backoff cuts steady-state CPU well under the 2% target).
- macOS battery / power APIs: <https://developer.apple.com/documentation/iokit/ioptypes>
- Windows network cost API: <https://learn.microsoft.com/en-us/uwp/api/windows.networking.connectivity.networkcosttype>
