# Agent host (`AgentKit.RepoAgent`)

How a single Sprig process composes the watcher, refresher, broadcaster, subscription registry, and IPC layer into a long-lived host that drives badge updates for one or more repos and serves one or more connected clients. Slices A → A5 of the M2 agent track.

ADR cross-references: 0021 (perf budget), 0024 (fsmonitor source of truth, outgoing), 0048 (cross-platform IPC tier discipline), 0056 (external-git-agent awareness, incoming), 0057 (commands panel default — `RunnerLog` is what feeds it), 0066 (stale `index.lock` recovery — `RepoRefreshDriver.firstDeferralAt` is the observable for the eventual one-click clear).

## Outbound pipeline (badge changes flow agent → client)

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
       └──► TransportBadgeEventSink (AgentKit) — encode envelope + send
                                                 via TransportKit.Transport
```

## Inbound pipeline (client requests flow client → agent)

```
TransportKit.Transport.messages() — AsyncStream<Data>
       │
       ▼
ClientRequestDispatcher (AgentKit actor) — drains the stream,
       │                                    decodes Envelope<ClientRequest>,
       │                                    dispatches by kind
       │
       ├──► subscribe → SubscriptionRegistry.subscribe(roots:)
       │              → Envelope<AgentResponse>.subscribeAck
       │
       ├──► badgeQuery → BadgeResolver closure (host-supplied)
       │              → Envelope<AgentResponse>.badgeReply
       │
       └──► (parse error / unknown kind)
                       → Envelope<AgentResponse>.error
                         (wire-stable code: unknown_message_kind,
                          unsupported_schema_version, parse_error)
```

Both pipelines share one `Transport` and one `SubscriptionRegistry`, so a `subscribe` request from the client immediately enrols the new id in the registry the broadcaster reads from on the next refresh tick.

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

## Composing the full host (single client)

For a single-client host like `sprigctl agent` over an in-process transport, or the M2-Mac LaunchAgent over XPC, the wiring is three components sharing one `Transport` and one `SubscriptionRegistry`:

```swift
let pair = InProcessTransportPair.connected()  // or: XPC transport pair
let registry = SubscriptionRegistry()

// Outbound side: agent → client.
let sink = TransportBadgeEventSink(transport: pair.agentEnd)
let agent = RepoAgent(
    repoRoot: repoRoot,
    gitDir: gitDir,
    runner: runner,
    watcher: watcher,
    registry: registry,
    sink: sink
)

// Inbound side: client → agent.
let dispatcher = ClientRequestDispatcher(
    transport: pair.agentEnd,
    registry: registry,
    badgeResolver: { url in
        // Host decides which RepoStateStore answers each path.
        // Single-repo hosts can hand a closure that consults the
        // one store; multi-repo hosts route by path-prefix.
        nil
    }
)

try await agent.start()
await dispatcher.start()
```

Both `agent` and `dispatcher` share `pair.agentEnd`. Concurrent `transport.send(_:)` calls are safe per the `Transport` protocol's `Sendable` requirement. The client side reads `pair.clientEnd.messages()` and peeks each envelope's `kind` before deciding "this is a reply, correlate by id" vs. "this is an event, route to the subscription handler" — `IPCSchema.EnvelopePeek` provides the cheap pre-decode.

## Composing the full host (multi-client)

For hosts serving more than one connected client — the M2-Mac LaunchAgent serving multiple FinderSync extension instances, a sprigctl-agent serving a CLI subscriber alongside a task-window app — the single-client wiring leaks events across clients (`TransportBadgeEventSink` writes every emit to its one configured transport). The multi-client wiring swaps that one piece for a router:

```swift
let registry = SubscriptionRegistry()
let routes = SubscriptionTransportRoutes()  // shared across all clients

// Outbound side: one RepoAgent per watched repo, all using a sink
// that routes by subscription id rather than to a single transport.
let sink = RoutedBadgeEventSink(routes: routes)
let agent = RepoAgent(
    repoRoot: repoRoot,
    gitDir: gitDir,
    runner: runner,
    watcher: watcher,
    registry: registry,
    sink: sink
)

// Inbound side: one ClientRequestDispatcher per connected client.
// `routes` is passed in so each successful `subscribe` ack also
// associates the assigned id with this client's transport.
func wireClient(transport: any Transport) async -> ClientRequestDispatcher {
    let dispatcher = ClientRequestDispatcher(
        transport: transport,
        registry: registry,
        routes: routes  // ← the only addition vs single-client
    )
    await dispatcher.start()
    return dispatcher
}

try await agent.start()
let dispatcherA = await wireClient(transport: pairA.agentEnd)
let dispatcherB = await wireClient(transport: pairB.agentEnd)
```

When the broadcaster fans out a `[PathBadgeChange]` to N matching subscriptions, `RoutedBadgeEventSink.emit(_:)` consults `routes.transport(for: subscriptionId)` per envelope. Subscriptions owned by client A produce envelopes that reach client A's transport; B's stay on B's. Subscriptions whose owners disconnected (no mapping in `routes`) are silently dropped.

**Connection cleanup.** When a client disconnects, the host should call `routes.unregisterAll(transport: theirTransport)` to drop every mapping pointing at that transport — otherwise dead-transport sends accumulate and `RoutedBadgeEventSink` keeps trying to write to a closed connection. The dispatcher's `messages()` loop ending is the natural trigger; whatever owns the connection lifecycle (the M2-Mac XPC listener, sprigctl's connection handler) calls `unregisterAll(transport:)` from its disconnect path.

**Single-client hosts** can keep using `TransportBadgeEventSink` and pass `routes: nil` to `ClientRequestDispatcher` — the multi-client types are additive, not replacements.

## What `RepoAgent` does NOT do (deliberate)

- **IPC dispatch.** `RepoAgent` writes events outbound but doesn't read inbound. Use `ClientRequestDispatcher` for the inbound side; the two compose via a shared `SubscriptionRegistry`. The "Composing the full host" sections above show the pattern in single- and multi-client form.
- **Multi-repo orchestration.** One `RepoAgent` watches one repo. The CLI's `sprigctl agent` accepts a single `--repo`; multi-repo agents (the macOS LaunchAgent host, the Windows Service host) construct one `RepoAgent` per watched repo and let them share a `Runner` + `SubscriptionRegistry` + `SubscriptionTransportRoutes`.
- **Auto-cleanup on transport drop.** `SubscriptionTransportRoutes.unregisterAll(transport:)` is the primitive; wiring it to a transport-closed signal is the host's call. `Transport` currently surfaces `peerClosed` only on send failure — a dedicated closed-callback can land if multiple hosts grow the same wiring.
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
2. On startup, discover repos (via `RepoState.RepoDiscovery`) and spin up one `RepoAgent` per discovered repo, all sharing one `SubscriptionRegistry` and one `SubscriptionTransportRoutes`.
3. Set up an XPC `Transport` adapter (replaces `InProcessTransport` in the composition pattern above).
4. For each connecting FinderSync client, construct a `ClientRequestDispatcher` against that client's transport with the shared `routes`. The agents' shared `RoutedBadgeEventSink` then delivers events for that client's subscriptions to that client's transport.
5. On disconnect, call `routes.unregisterAll(transport:)` to drop every mapping for the gone client.

Slices A → A5 deliver step 0 (`RepoAgent` core, transport sink, request dispatcher, single-client integration test, multi-client routing). Steps 1–5 are M2-Mac scope.
