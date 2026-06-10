// RepoAgent.swift
//
// Single-process composition of the agent pipeline for one watched
// repo:
//
//   FileWatcher.start(paths:)
//     → EventCoalescer.ingest / drain (per tick)
//       → RepoRefreshDriver.processEvents
//         → RepoStatusRefresher.refresh
//           → RepoStateStore.applyAndDiff (returns the badge diff)
//             → BadgeChangeBroadcaster.broadcast
//               → SubscriptionRegistry.matchingSubscriptions
//                 → BadgeEventSink.emit (in-process for slice A;
//                   Transport-backed sink lands in a follow-up)
//
// What this type DOES NOT do (deliberate):
//
// - **Lifecycle** — registering as a LaunchAgent on macOS, a systemd
//   user unit on Linux, or a Windows Service. That's tier-2 platform
//   work for `Sources/Mac/`, `Sources/Linux/`, `Sources/Windows/`.
//   `RepoAgent` is the long-lived business logic those hosts run.
// - **IPC dispatch** — decoding inbound `ClientRequest` envelopes
//   from a `Transport` and routing subscribe/unsubscribe to the
//   registry. Slice A subscribes the agent's own root at start and
//   never reads from a transport. The dispatch loop lands when the
//   Transport-backed sink does.
//
// Tier-2 portable. Carries no platform APIs and no `#if os(...)`;
// callers pick the watcher (FSEvents on macOS, polling elsewhere
// today) and pass it in.

import Foundation
import GitCore
import IPCSchema
import PlatformKit
import RepoState
import WatcherKit

/// Long-lived agent host for one repository. Owns the watcher loop,
/// the refresh driver, and the broadcaster wiring; emits
/// `Envelope<AgentEvent>` to its `BadgeEventSink` on every refresh
/// that produces a non-empty diff.
///
/// **Construction.** Callers (CLI, macOS LaunchAgent host, Windows
/// Service host) build the dependencies and pass them in. The agent
/// constructs its own `RepoStateStore`, `RepoStatusRefresher`,
/// `RepoRefreshDriver`, and `BadgeChangeBroadcaster` from the inputs;
/// these are not exposed because callers shouldn't be poking at
/// internal pipeline stages mid-flight.
///
/// **Lifecycle.** `start()` launches the watcher loop, forces an
/// initial refresh so the store is populated, and (per
/// ``SnapshotPolicy``) runs a one-shot TTL prune of
/// `refs/sprig/snapshots/...`. `stop()` cancels the loop and stops
/// the watcher; safe to call multiple times.
///
/// **Why an actor.** The watcher loop, the coalescer, and the driver
/// state are all mutated from concurrent tasks (watcher producer task,
/// tick consumer task, external `stop()` caller). Actor isolation is
/// the cheapest correct serialization.
public actor RepoAgent {
    /// Repo worktree root.
    public let repoRoot: URL

    /// Resolved `.git` directory (handles submodule pointer files
    /// per ADR 0056). Pass `nil` only when the caller can't resolve
    /// it; the driver's noise-filter is conservative without it.
    public let gitDir: URL?

    private let gitVersion: GitVersion?
    private let runner: Runner
    private let watcher: any FileWatcher
    private let registry: SubscriptionRegistry
    private let sink: any BadgeEventSink
    private let tickInterval: Duration
    private let snapshotPolicy: SnapshotPolicy
    private let autoSync: AutoSyncStartup?
    private let autoBackup: AutoBackupStartup?

    private var coalescer: EventCoalescer
    private var driver: RepoRefreshDriver?
    private var broadcaster: BadgeChangeBroadcaster?
    private var loop: Task<Void, Never>?
    private var running: Bool = false
    private var snapshotPruneCount: Int = 0
    private var snapshotPruneAt: Date?
    private var autoSyncScheduler: AutoSyncScheduler?
    private var autoBackupScheduler: AutoSyncScheduler?

    /// - Parameters:
    ///   - repoRoot: absolute path to the worktree root.
    ///   - gitDir: resolved `.git` directory. Use
    ///     `GitMetadataPaths.resolveGitDir(forWorktree:)` to compute.
    ///   - gitVersion: optional probed git version (for ADR 0056
    ///     version-aware hooks; today's filter rules don't switch
    ///     on it but the plumbing is in place).
    ///   - runner: shared `GitCore.Runner`. The agent will use it
    ///     for `git status` invocations; callers wishing to capture
    ///     every invocation should attach a `RunnerLog` *before*
    ///     constructing the runner (see ADR 0057).
    ///   - watcher: a `FileWatcher` already configured for this
    ///     platform. The agent calls `start(paths:)` once and `stop()`
    ///     once.
    ///   - registry: the `SubscriptionRegistry` that maps subscriber
    ///     UUIDs to roots. May be shared across multiple `RepoAgent`s
    ///     in the same host process.
    ///   - sink: where `Envelope<AgentEvent>` goes. In slice A the
    ///     CLI uses `InMemoryBadgeEventSink`; Transport-backed sinks
    ///     come later.
    ///   - tickInterval: coalescer drain cadence. Default 100 ms is
    ///     the FSEvents/inotify natural batching window — small enough
    ///     to feel instant, large enough to absorb editor "save many
    ///     events at once" bursts.
    ///   - snapshotPolicy: ADR 0033 snapshot-housekeeping policy.
    ///     Default prunes refs older than 30 days on startup; tests
    ///     and repos where the caller manages snapshots manually
    ///     should pass `.disabled`.
    ///   - autoSync: ADR 0068 background-sync wiring; nil (default)
    ///     disables it. Hosts that want the hourly fetch pass
    ///     `AutoSyncStartup()`; `fastForwardPull: true` adds the
    ///     opt-in fast-forward pass.
    ///   - autoBackup: ADR 0075 uncommitted-work insurance; nil
    ///     (default) disables it. `AutoBackupStartup()` gives the
    ///     30-minute / 7-day-TTL defaults.
    public init(
        repoRoot: URL,
        gitDir: URL?,
        gitVersion: GitVersion? = nil,
        runner: Runner,
        watcher: any FileWatcher,
        registry: SubscriptionRegistry,
        sink: any BadgeEventSink,
        tickInterval: Duration = .milliseconds(100),
        snapshotPolicy: SnapshotPolicy = .default,
        autoSync: AutoSyncStartup? = nil,
        autoBackup: AutoBackupStartup? = nil
    ) {
        self.repoRoot = repoRoot
        self.gitDir = gitDir
        self.gitVersion = gitVersion
        self.runner = runner
        self.watcher = watcher
        self.registry = registry
        self.sink = sink
        self.tickInterval = tickInterval
        self.snapshotPolicy = snapshotPolicy
        self.autoSync = autoSync
        self.autoBackup = autoBackup
        coalescer = EventCoalescer()
    }

    /// Begin watching, refreshing, and broadcasting. Forces an
    /// initial `git status` on entry so the store is populated and
    /// any pre-existing badges fan out to subscribers registered
    /// before start. Idempotent — a second call while running is a
    /// no-op.
    public func start() async throws {
        guard !running else { return }
        running = true

        let store = RepoStateStore(repoRoot: repoRoot)
        let refresher = RepoStatusRefresher(store: store, runner: runner)
        let newBroadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)
        broadcaster = newBroadcaster

        // The driver's refresh closure does the canonical 3-step:
        // refresh → broadcast the diff → return the outcome to the
        // driver so its diagnostics (firstDeferralAt, refreshAttempts)
        // stay accurate. `BroadcastResult` is intentionally discarded
        // here — per-subscriber failures are isolated by the
        // broadcaster and the agent has no recovery action available
        // beyond what the broadcaster's logging already provides.
        let closureBroadcaster = newBroadcaster
        let refreshClosure: @Sendable () async -> RefreshOutcome = {
            let outcome = await refresher.refresh()
            if case let .applied(_, changes) = outcome, !changes.isEmpty {
                _ = await closureBroadcaster.broadcast(changes)
            }
            return outcome
        }

        let driver = RepoRefreshDriver(
            gitDir: gitDir,
            gitVersion: gitVersion,
            refresh: refreshClosure
        )
        self.driver = driver

        // Force an initial refresh so callers that subscribed before
        // start() see the current state, not a series of empty diffs.
        _ = await driver.forceRefresh()

        // ADR 0033 startup prune. Best-effort — failures here don't
        // block the agent from running. Order: AFTER the initial
        // refresh (so callers that observe refreshAttempts == 1 see
        // a stable post-refresh state) and BEFORE the watcher loop
        // (so a one-shot startup task isn't racing the live update
        // path). On a repo with no snapshots this is one
        // `git for-each-ref` returning empty — tens of milliseconds.
        if snapshotPolicy.pruneOnStartup {
            await runStartupPrune()
        }

        // Watch the worktree AND the resolved gitDir per ADR 0056.
        // Some callers may pass gitDir=nil (e.g. tests with a fake
        // path); honor that by watching only the worktree.
        let paths: [URL] = [repoRoot] + (gitDir.map { [$0] } ?? [])
        let stream = watcher.start(paths: paths)

        loop = makeWatcherLoop(stream: stream)

        // ADR 0068 auto-sync. Started LAST so a fetch firing at start
        // can't race agent bring-up; the watcher loop above turns any
        // ref movement the fetch causes into badge refreshes for free.
        // (Construction lives in RepoAgent+AutoSync.swift.)
        if let autoSync {
            autoSyncScheduler = await Self.startAutoSyncScheduler(
                autoSync,
                runner: runner,
                gitDir: gitDir
            )
        }

        // ADR 0075 auto-backup — same lifecycle shape as auto-sync.
        // (Construction lives in RepoAgent+AutoBackup.swift.)
        if let autoBackup {
            autoBackupScheduler = await Self.startAutoBackupScheduler(
                autoBackup,
                runner: runner
            )
        }
    }

    /// Stop the watcher loop and the underlying watcher. Before
    /// returning, fans an
    /// ``IPCSchema/AgentEvent/subscriptionEnded`` envelope (reason
    /// `"agent_shutdown"`) out to every still-active subscription in
    /// the registry, so connected clients learn their subscriptions
    /// are gone without waiting for the transport itself to disconnect.
    ///
    /// Safe to call multiple times. The shutdown broadcast only
    /// happens on the first call (gated on `running`); subsequent
    /// calls return immediately.
    ///
    /// After stop returns, the sink's stream may still have buffered
    /// events — drain it (or call `finish()` on an
    /// `InMemoryBadgeEventSink`) if the consumer needs to terminate.
    ///
    /// Diagnostic accessors below remain readable after `stop()` —
    /// they reflect the state of the last refresh that ran. Useful for
    /// "agent stopped, what did it manage to do?" inspection.
    public func stop() async {
        guard running else { return }
        running = false

        // Auto-sync/backup first: stop scheduling new background work
        // before tearing down the pipeline it'd feed.
        if let autoSyncScheduler {
            await autoSyncScheduler.stop()
            self.autoSyncScheduler = nil
        }
        if let autoBackupScheduler {
            await autoBackupScheduler.stop()
            self.autoBackupScheduler = nil
        }

        // Tell every active subscriber their subscription is gone.
        // Done before cancelling the watcher loop / stopping the watcher
        // so the sink and registry are still in a workable state.
        // `agent_shutdown` is the wire-stable reason from
        // `IPCSchema.SubscriptionEndedPayload`'s documented value list.
        if let broadcaster {
            _ = await broadcaster.broadcastSubscriptionEnded(reason: "agent_shutdown")
        }

        loop?.cancel()
        loop = nil
        await watcher.stop()
    }

    // MARK: diagnostics

    /// Total refresh-closure invocations the underlying
    /// ``RepoRefreshDriver`` has made since this agent started. Zero
    /// before ``start()`` and immediately after — the initial forced
    /// refresh in `start()` increments to 1.
    ///
    /// Surface for `sprigctl status`-style introspection and the
    /// future M2-Mac UI's "agent activity" panel.
    public func refreshAttempts() async -> Int {
        await driver?.refreshAttempts ?? 0
    }

    /// Most recent ``RefreshOutcome`` from the driver, or nil if the
    /// driver hasn't run yet (i.e. before ``start()`` and immediately
    /// after, before the forced initial refresh completes).
    public func lastOutcome() async -> RefreshOutcome? {
        await driver?.lastOutcome
    }

    /// Forward-compat enabler for ADR 0066 (stale `index.lock`
    /// recovery). When non-nil, the wall-clock timestamp of the first
    /// `.deferred` outcome in the current consecutive deferral streak.
    /// Cleared on success or failure. Hosts can compute "how long has
    /// this repo been stuck mid-mutation?" via
    /// `Date().timeIntervalSince(...)` and surface a notification when
    /// elapsed > 60 s, offering one-click clear of the stale lock.
    public func firstDeferralAt() async -> Date? {
        await driver?.firstDeferralAt
    }

    /// Number of `refs/sprig/snapshots/...` refs the startup prune
    /// deleted. Zero before ``start()`` runs, after a `.disabled`
    /// policy run, and after a prune failure (best-effort — see
    /// `start()` notes).
    public func lastSnapshotPruneCount() -> Int {
        snapshotPruneCount
    }

    /// Wall-clock time of the last successful startup prune, or nil
    /// before one has run (or if the prune failed).
    public func lastSnapshotPruneAt() -> Date? {
        snapshotPruneAt
    }

    // MARK: actor-internal helpers

    /// The watcher loop's two cooperating tasks: an ingestion task
    /// that pulls events into the coalescer, and a tick task that
    /// drains and dispatches at `tickInterval`. They share state via
    /// the actor — each `await self.…` call serializes through actor
    /// isolation, which is the right behavior. Factored out of
    /// `start()` for SwiftLint's function-body cap.
    private func makeWatcherLoop(stream: AsyncStream<WatchEvent>) -> Task<Void, Never> {
        let capturedTickInterval = tickInterval
        return Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    for await event in stream {
                        await self.ingest(event)
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: capturedTickInterval)
                        if Task.isCancelled { break }
                        guard let self else { return }
                        await self.tick()
                    }
                }
                await group.waitForAll()
            }
        }
    }

    /// One-shot startup TTL prune of `refs/sprig/snapshots/...`. Errors
    /// from `git for-each-ref` / `git update-ref --stdin` are
    /// swallowed — pruning is housekeeping, not load-bearing for
    /// badge correctness. Diagnostics (``lastSnapshotPruneCount()``,
    /// ``lastSnapshotPruneAt()``) stay at their defaults on failure
    /// so callers that want to monitor health can detect the absence
    /// of a successful prune.
    private func runStartupPrune() async {
        let index = SnapshotIndex(runner: runner)
        do {
            try await index.refresh()
            let cutoff = Date().addingTimeInterval(-snapshotPolicy.ttl)
            let pruned = try await index.prune(olderThan: cutoff)
            snapshotPruneCount = pruned.count
            snapshotPruneAt = Date()
        } catch {
            // Best-effort — leave diagnostics at their defaults. A
            // future slice can add structured error reporting via
            // `RunnerLog` (ADR 0057) once the agent host has a
            // logging surface.
        }
    }

    /// Ingest one watcher event into the coalescer. Called by the
    /// watcher-stream task; serialized through actor isolation.
    private func ingest(_ event: WatchEvent) {
        coalescer.ingest(event)
    }

    /// One tick: drain the coalescer up to "now" and feed the batch
    /// into the driver. The driver decides whether the batch warrants
    /// a refresh; the refresh closure (set up in `start()`) does the
    /// broadcast on `.applied(_, changes)`.
    private func tick() async {
        guard let driver else { return }
        let batch = coalescer.drain(upTo: Date())
        _ = await driver.processEvents(batch)
    }
}
