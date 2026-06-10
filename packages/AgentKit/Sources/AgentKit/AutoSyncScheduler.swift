// AutoSyncScheduler.swift
//
// ADR 0068's periodic driver: fires a sync job (typically
// `SyncOps.fetchAll` + optional fast-forward pass) on an interval —
// hourly by default — with jitter, a per-tick `SyncPolicy` gate, and
// an overlap guard.
//
// Deliberately generic over "the job": the scheduler owns *when*,
// the host owns *what*. That keeps it testable with a counter
// closure and reusable for future periodic work (auto-backup
// snapshots, maintenance kicks) without new scheduling code.
//
// Tier-2 portable; no platform APIs. The platform-aware pause logic
// lives behind `PlatformKit.SyncPolicy`.

import Foundation
import PlatformKit

/// Cadence + behavior knobs for an ``AutoSyncScheduler``.
public struct AutoSyncConfiguration: Sendable, Equatable {
    /// Time between job firings. ADR 0068 default: one hour.
    public var interval: Duration

    /// ± fraction of `interval` randomized per tick so a fleet of
    /// repos doesn't fetch in lockstep. 0 disables (tests).
    /// Clamped to `0...0.5`.
    public var jitterFraction: Double

    /// Fire once immediately on ``AutoSyncScheduler/start()`` rather
    /// than waiting a full interval (ADR 0064: newly-added repos are
    /// fetched once on registration).
    public var fireOnStart: Bool

    public init(
        interval: Duration = .seconds(3600),
        jitterFraction: Double = 0.1,
        fireOnStart: Bool = true
    ) {
        self.interval = interval
        self.jitterFraction = min(max(jitterFraction, 0), 0.5)
        self.fireOnStart = fireOnStart
    }

    /// The ADR 0068 default: hourly, ±10 % jitter, fetch on start.
    public static let hourly = AutoSyncConfiguration()
}

/// Periodic job runner with policy gating.
///
/// **Lifecycle.** `start()` launches the tick loop (idempotent);
/// `stop()` cancels it and awaits its exit (idempotent, safe to call
/// without `start()`). `fireNow()` runs the job immediately —
/// the Status window's "Fetch now" button — independent of the loop,
/// still respecting the overlap guard but bypassing the policy
/// (an explicit user action overrides backoff, per ADR 0064's
/// "Force fetch now" semantics).
///
/// **Overlap guard.** If a tick (or `fireNow()`) lands while the
/// previous job is still running, it's skipped and counted — a slow
/// fetch never stacks a second fetch behind it.
public actor AutoSyncScheduler {
    /// Observable counters for the Status surface + tests.
    public struct Diagnostics: Sendable, Equatable {
        public var firesCompleted: Int = 0
        public var ticksSkippedByPolicy: Int = 0
        public var ticksSkippedOverlapping: Int = 0
        public var lastPauseReason: String?

        public init() {}
    }

    private let configuration: AutoSyncConfiguration
    private let policy: any SyncPolicy
    private let job: @Sendable () async -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    private var loop: Task<Void, Never>?
    private var jobRunning = false
    private(set) var diagnosticsStorage = Diagnostics()

    /// - Parameters:
    ///   - configuration: cadence knobs; see ``AutoSyncConfiguration``.
    ///   - policy: per-tick gate; defaults to always-allow. Platform
    ///     hosts pass their ADR 0064 signal adapter.
    ///   - sleep: injectable so tests run ticks in microseconds.
    ///     Production default is `Task.sleep`.
    ///   - job: the work. Errors are the job's own business — wrap
    ///     and log inside; the scheduler only sequences.
    public init(
        configuration: AutoSyncConfiguration = .hourly,
        policy: any SyncPolicy = AlwaysAllowSyncPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        job: @escaping @Sendable () async -> Void
    ) {
        self.configuration = configuration
        self.policy = policy
        self.sleep = sleep
        self.job = job
    }

    /// Current counters (value snapshot).
    public func diagnostics() -> Diagnostics {
        diagnosticsStorage
    }

    /// Launch the tick loop. Idempotent while running.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancel the tick loop and await its exit. Idempotent.
    public func stop() async {
        guard let running = loop else { return }
        running.cancel()
        _ = await running.value
        loop = nil
    }

    /// Run the job immediately (user-initiated "Fetch now").
    /// Bypasses the policy gate; still refuses to overlap a job
    /// already in flight (returns false in that case).
    @discardableResult
    public func fireNow() async -> Bool {
        await runJob(gatedByPolicy: false)
    }

    // MARK: - Internals

    private func runLoop() async {
        if configuration.fireOnStart {
            _ = await runJob(gatedByPolicy: true)
        }
        while !Task.isCancelled {
            do {
                try await sleep(jitteredInterval())
            } catch {
                break // cancellation
            }
            if Task.isCancelled { break }
            _ = await runJob(gatedByPolicy: true)
        }
    }

    private func jitteredInterval() -> Duration {
        let jitter = configuration.jitterFraction
        guard jitter > 0 else { return configuration.interval }
        let factor = Double.random(in: (1 - jitter) ... (1 + jitter))
        let scaled = configuration.interval * factor
        // Never below a floor of 1s, however aggressive the jitter.
        return max(scaled, .seconds(1))
    }

    private func runJob(gatedByPolicy: Bool) async -> Bool {
        if jobRunning {
            diagnosticsStorage.ticksSkippedOverlapping += 1
            return false
        }
        if gatedByPolicy, case let .pause(reason) = policy.decision() {
            diagnosticsStorage.ticksSkippedByPolicy += 1
            diagnosticsStorage.lastPauseReason = reason
            return false
        }
        jobRunning = true
        await job()
        jobRunning = false
        diagnosticsStorage.firesCompleted += 1
        return true
    }
}
