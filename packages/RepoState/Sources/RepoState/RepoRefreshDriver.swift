// RepoRefreshDriver.swift
//
// Decides "does this batch of filesystem events warrant a `git
// status` refresh?" and drives a ``RepoStatusRefresher`` accordingly.
//
// Used by the agent's main loop. The watcher (FSEvents on macOS,
// PollingFileWatcher on Linux/Windows, ReadDirChangesW on Windows
// later) emits a stream of `WatchEvent`s; the agent batches them
// through an `EventCoalescer` and feeds each tick's drained batch
// into ``processEvents(_:)``. The driver:
//
// 1. Filters out events that are pure git-internal noise (lock files
//    being created/deleted inside `.git/` during a `git commit` are
//    transient mid-mutation state, not changes Sprig should react
//    to) per ADR 0056 / `GitMetadataPaths.isLockOrTempPath`.
// 2. Triggers a refresh when any non-noise event is in the batch,
//    when an `.overflow` event arrives (forces a full rescan), or
//    when the previous refresh was `.deferred(.gitOperationInFlight)`
//    and we're now re-entering with any batch — including empty —
//    because the next tick is the natural retry boundary.
// 3. Calls the refresh closure exactly once per tick that warrants
//    it. Out-of-order or concurrent refreshes are not produced from
//    here; if multiple ticks fire in flight, the agent's coalescer
//    upstream is responsible for serializing.
//
// Tier-1 portable. Depends on Foundation + GitCore (for `GitVersion`,
// `GitMetadataPaths`) + PlatformKit (for `WatchEvent`). No platform
// APIs, no UI imports, no `#if os(...)` outside trivial constants.

import Foundation
import GitCore
import PlatformKit

/// Drives a ``RepoStatusRefresher`` from a watcher's event stream.
///
/// One driver per watched repo. The agent constructs the driver with
/// the repo's resolved git directory (so the noise filter knows what
/// counts as "inside `.git/`"); on each watcher tick, the agent calls
/// ``processEvents(_:)`` with that tick's drained batch.
///
/// **Why an actor.** The agent runs concurrent tasks (one per repo,
/// one per IPC connection); the driver's pending-deferred flag and
/// diagnostic counters need isolation. Actor is the cheapest correct
/// answer; we never need re-entrancy.
public actor RepoRefreshDriver {
    /// What the driver invokes when it decides to refresh. Wraps a
    /// ``RepoStatusRefresher`` in production; tests pass a closure
    /// that records calls without spawning git.
    public typealias RefreshCall = @Sendable () async -> RefreshOutcome

    private let refresh: RefreshCall
    private let gitDir: URL?
    private let gitVersion: GitVersion?

    /// True if the last refresh attempt returned `.deferred`. The
    /// next ``processEvents(_:)`` call will retry regardless of the
    /// batch's contents — the next tick is when the lock has typically
    /// cleared (<100 ms) so we don't want to wait for the next
    /// worktree event before re-checking.
    private var hasPendingDeferred = false

    /// Wall-clock timestamp of the *first* `.deferred` outcome in the
    /// current run of consecutive deferrals. Cleared back to nil the
    /// moment a refresh succeeds or fails (i.e. the deferral streak
    /// ends). Stays at the *first* timestamp across a streak, not the
    /// most-recent — so callers can compute "how long has this repo
    /// been stuck mid-mutation?" via `Date().timeIntervalSince(first)`.
    ///
    /// Forward-compat for **ADR 0066** (stale `index.lock` recovery):
    /// the agent's main loop will check this on every tick, and when
    /// elapsed > 60s it surfaces a Notification Center alert offering
    /// one-click clear of the stale lock. Driver itself takes no
    /// action on the timestamp — it's an observable for the agent.
    public private(set) var firstDeferralAt: Date?

    /// Total number of refresh-closure invocations the driver made.
    /// Diagnostic only — the agent's `sprigctl status` plumbing reads
    /// this via the actor's getter.
    public private(set) var refreshAttempts: Int = 0

    /// The most recent refresh outcome, or nil if the driver hasn't
    /// run a refresh yet. Diagnostic.
    public private(set) var lastOutcome: RefreshOutcome?

    /// Closure-form initializer. Tests use this with a recording
    /// closure; production wraps a ``RepoStatusRefresher`` in a thin
    /// `{ await refresher.refresh() }` closure (see the convenience
    /// init below).
    public init(
        gitDir: URL?,
        gitVersion: GitVersion? = nil,
        refresh: @escaping RefreshCall
    ) {
        self.gitDir = gitDir
        self.gitVersion = gitVersion
        self.refresh = refresh
    }

    /// Convenience: wrap a concrete ``RepoStatusRefresher``. The
    /// driver captures the refresher (a `Sendable` struct) and
    /// invokes its `refresh()` method.
    public init(
        refresher: RepoStatusRefresher,
        gitDir: URL?,
        gitVersion: GitVersion? = nil
    ) {
        self.gitDir = gitDir
        self.gitVersion = gitVersion
        refresh = { await refresher.refresh() }
    }

    // MARK: tick processing

    /// Process a watcher tick's drained batch. Returns the refresh
    /// outcome if the driver triggered one, or `nil` if the batch was
    /// pure noise and no prior deferral was pending.
    ///
    /// **Refresh-trigger rules:**
    /// - Any event with `.kind == .overflow` triggers immediately —
    ///   the watcher lost track and the worktree must be re-scanned.
    /// - Any event whose path is **not** a git-internal lock/temp
    ///   path triggers a refresh. This includes worktree changes
    ///   AND legitimate `.git/`-internal file rewrites (e.g. `index`,
    ///   `HEAD`, `refs/heads/main`) — those are exactly the signals
    ///   we care about for "external git agent committed something."
    /// - If the prior refresh was `.deferred(.gitOperationInFlight)`,
    ///   the next call retries even if the batch is otherwise pure
    ///   noise (or empty). Lock files typically clear in <100 ms;
    ///   the next tick is the natural retry point.
    @discardableResult
    public func processEvents(_ events: [WatchEvent]) async -> RefreshOutcome? {
        let triggered = hasPendingDeferred || shouldTriggerRefresh(events)
        guard triggered else { return nil }
        return await runRefresh()
    }

    /// Force a refresh, regardless of event filters or pending state.
    /// Used by the agent when it explicitly knows a refresh is due
    /// (initial subscribe, manual `sprigctl refresh`, IPC-driven
    /// "force refresh"). Equivalent to `processEvents([overflow event])`
    /// in effect, but doesn't require synthesizing an event.
    @discardableResult
    public func forceRefresh() async -> RefreshOutcome {
        await runRefresh()
    }

    // MARK: internals

    private func runRefresh() async -> RefreshOutcome {
        refreshAttempts += 1
        let outcome = await refresh()
        lastOutcome = outcome
        switch outcome {
        case .deferred:
            hasPendingDeferred = true
            // Set firstDeferralAt only if this starts a new streak.
            // Across a streak we keep the *first* timestamp so callers
            // can measure total elapsed deferred time, not just the
            // gap since the most-recent attempt.
            if firstDeferralAt == nil {
                firstDeferralAt = Date()
            }
        case .applied, .failed:
            hasPendingDeferred = false
            firstDeferralAt = nil
        }
        return outcome
    }

    /// True if any event in `events` represents a "real" change.
    ///
    /// "Real" means the event is either an overflow (always real), or
    /// the path is outside `.git/`, or the path is inside `.git/` but
    /// is not a lock/temp file. Lock files getting created and deleted
    /// during a `git commit` are transient mid-mutation state, not
    /// signals worth refreshing on.
    private func shouldTriggerRefresh(_ events: [WatchEvent]) -> Bool {
        for event in events {
            if event.kind == .overflow {
                return true
            }
            if isReal(event) {
                return true
            }
        }
        return false
    }

    private func isReal(_ event: WatchEvent) -> Bool {
        guard let gitDir else {
            // No gitDir resolved → assume the event is meaningful.
            // This is the conservative default — the driver still
            // works if `GitMetadataPaths.resolveGitDir` failed at
            // construction.
            return true
        }
        return !GitMetadataPaths.isLockOrTempPath(
            event.path,
            in: gitDir,
            gitVersion: gitVersion
        )
    }
}
