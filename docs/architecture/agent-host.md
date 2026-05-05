# Agent host (`AgentKit.RepoAgent`)

How a single Sprig process composes the watcher, refresher, broadcaster, and subscription registry into a long-lived host that drives badge updates for one repo. Slice A of the M2 agent track.

ADR cross-references: 0021 (perf budget), 0024 (fsmonitor source of truth, outgoing), 0048 (cross-platform IPC tier discipline), 0056 (external-git-agent awareness, incoming), 0057 (commands panel default — `RunnerLog` is what feeds it), 0066 (stale `index.lock` recovery — `RepoRefreshDriver.firstDeferralAt` is the observable for the eventual one-click clear).

## Pipeline

```
FileWatcher (PlatformKit protocol; FSEventsWatcher on macOS,
             PollingFileWatcher elsewhere; MockFileWatcher for tests)
       │
       │  AsyncStream<WatchEvent>
       ▼
EventCoalescer (PlatformKit, pure value) — priority-weighted dedupe
       │
       │  draining ticks of [WatchEvent]
       ▼
RepoRefreshDriver (RepoState actor) — filters lock/temp paths
       │                                (ADR 0056), defers when
       │                                gitOperationInFlight
       │
       │  refresh closure call
       ▼
RepoStatusRefresher (RepoState struct) — runs `git status -z` via
       │                                  GitCore.Runner; calls
       │                                  store.applyAndDiff(_:)
       │
       │  RefreshOutcome.applied(entryCount, changes)
       ▼
RepoStateStore (RepoState actor) — path-trie of badges
       │
       │  [PathBadgeChange]
       ▼
BadgeChangeBroadcaster (RepoState struct) — fan-out
       │
       │  Envelope<AgentEvent>.badgeChanged per matching subscription
       ▼
SubscriptionRegistry (RepoState actor) — UUID-keyed roots
       │
       ▼
BadgeEventSink (protocol, RepoState)
       │
       ├──► InMemoryBadgeEventSink (AgentKit) — AsyncStream for the
       │                                       CLI / tests
       │
       └──► (planned) TransportBadgeEventSink — encode envelope + send
                                                via TransportKit.Transport
```

The shaded arrow at the bottom is the slice A2 follow-up: a sink that wraps `EnvelopeCodec` + `Transport` so a real client process can subscribe over XPC / named pipe / etc. Slice A delivers the in-process pipeline; the transport-backed sink is one focused PR after.

## `AgentKit.RepoAgent`

Tier-2-portable actor that owns one repo's pipeline. Construction takes the dependencies (worktree URL, gitDir, runner, watcher, registry, sink); the agent constructs its own `RepoStateStore`, `RepoStatusRefresher`, `RepoRefreshDriver`, and `BadgeChangeBroadcaster` from those inputs.

```swift
public actor RepoAgent {
    public init(
        repoRoot: URL,
        gitDir: URL?,
        gitVersion: GitVersion? = nil,
        runner: Runner,
        watcher: any FileWatcher,
        registry: SubscriptionRegistry,
        sink: any BadgeEventSink,
        tickInterval: Duration = .milliseconds(100)
    )

    public func start() async throws
    public func stop() async
}
```

`start()` is idempotent and forces an initial refresh so subscribers registered before start see the current state, not a series of empty diffs. `stop()` cancels the watcher loop and stops the watcher. The agent is `Sendable` (an actor), so callers can hand it across task boundaries without ceremony.

## Tier discipline

`RepoAgent` lives in `packages/AgentKit/Sources/AgentKit/` (the portable layer). Per CLAUDE.md, Tier-2 packages may carry portable code in their protocol-level directory when no platform APIs are involved. `RepoAgent` doesn't import AppKit / SwiftUI / FinderSync / etc., uses no `#if os(...)` branches for behavior, and runs on macOS, Linux, and Windows toolchains alike.

Platform-specific lifecycle (macOS LaunchAgent registration via `SMAppService`, Linux systemd user unit, Windows Service host) lands in `Sources/Mac/AgentKitMac.swift`, `Sources/Linux/AgentKitLinux.swift`, `Sources/Windows/AgentKitWindows.swift` as separate concerns; those files own the "how is this process kept alive across reboots?" question. The agent itself is just the long-lived business logic those hosts run.

## What `RepoAgent` does NOT do (deliberate)

- **IPC dispatch.** Decoding inbound `ClientRequest` envelopes from a `Transport` and routing `subscribe` / `unsubscribe` / `queryBadge` to the registry is out of scope for slice A. Slice A subscribes the agent's own root at start (via `sprigctl agent`) and never reads from a transport. The dispatch loop lands when the transport-backed sink does (slice A2).
- **Multi-repo orchestration.** One `RepoAgent` watches one repo. The CLI's `sprigctl agent` accepts a single `--repo`; multi-repo agents (the macOS LaunchAgent host, the Windows Service host) construct one `RepoAgent` per watched repo and let them share a `Runner` + `SubscriptionRegistry` if useful.
- **`core.fsmonitor` outgoing direction (ADR 0024).** That's a separate path served by `WatcherKit` directly; `RepoAgent` is the *incoming* direction (Sprig reacts to filesystem and external-git changes; the fsmonitor hook hands changes back *to* the user's git process).

## Diagnostics worth knowing

`RepoRefreshDriver` exposes three actor-readable observables that an agent host (or `sprigctl status`) can surface:

- `refreshAttempts: Int` — total refresh-closure invocations since process start.
- `lastOutcome: RefreshOutcome?` — the most recent outcome (or nil before the first refresh).
- `firstDeferralAt: Date?` — wall-clock timestamp of the first `.deferred` outcome in the current consecutive deferral streak. **Cleared on success or failure.** This is the forward-compat enabler for ADR 0066 — the agent's main loop will check this on every tick and surface a Notification Center alert when elapsed > 60 s, offering one-click clear of the stale lock.

`RunnerLog` (ADR 0057) is constructed by the agent's caller and attached to the `Runner` *before* the `Runner` is handed to `RepoAgent`. The agent does not consume the log; downstream features (Commands Panel) read it directly from the Runner. Splitting it this way means `RepoAgent` doesn't grow a Commands Panel concept and `RunnerLog` doesn't grow agent-lifecycle awareness.

## Where this slots into M1/M2

M1's exit-criterion list (see `docs/planning/milestones.md`) covered the building blocks: parser, watcher, refresher, store, broadcaster, registry, driver. `RepoAgent` is the first place that integrates them end-to-end in a runnable process, so it's the harness the remaining M1 perf-validation tranche (100k-file synthesized fixture, 10k-event watcher steady-state) will exercise before M2-Mac begins serious work.

For M2-Mac, the LaunchAgent host (`Sources/Mac/AgentKitMac.swift`) will:

1. Register the agent process via `SMAppService.daemon`.
2. On startup, discover repos (via `RepoState.RepoDiscovery`) and spin up one `RepoAgent` per discovered repo.
3. Set up a Transport-backed sink so the FinderSync extension's IPC client can subscribe and receive `Envelope<AgentEvent>` envelopes.
4. Wire in a `ClientRequest` dispatcher that decodes inbound IPC, calls `registry.subscribe(...)` / `unsubscribe(...)`, and returns `AgentResponse` envelopes.

Slice A delivers steps 0 (the `RepoAgent` core); steps 1–4 are M2-Mac scope.
