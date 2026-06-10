// RepoAgent+AutoSync.swift
//
// ADR 0068 auto-sync wiring for `RepoAgent` — the `AutoSyncStartup`
// configuration type plus the scheduler/job construction the agent's
// `start()` calls. Split out of RepoAgent.swift to stay under
// SwiftLint's file_length / function_body_length caps.

import Foundation
import GitCore
import PlatformKit

/// ADR 0068 auto-sync wiring for one agent. When non-nil, the agent
/// runs an ``AutoSyncScheduler`` whose job is `SyncOps.fetchAll`
/// (+ an optional fast-forward pass) against the agent's repo,
/// started in ``RepoAgent/start()`` and stopped in
/// ``RepoAgent/stop()``.
public struct AutoSyncStartup: Sendable {
    /// Cadence knobs. ADR 0068 default: hourly with jitter, fetch
    /// once at start.
    public var configuration: AutoSyncConfiguration

    /// Also fast-forward local branches after each fetch (the
    /// opt-in "default pull" — ADR 0068 safety table applies; the
    /// pass is skipped entirely while a git operation is in flight
    /// per ADR 0056).
    public var fastForwardPull: Bool

    /// Per-tick pause gate (ADR 0064 platform signals). Portable
    /// default never pauses.
    public var policy: any SyncPolicy

    public init(
        configuration: AutoSyncConfiguration = .hourly,
        fastForwardPull: Bool = false,
        policy: any SyncPolicy = AlwaysAllowSyncPolicy()
    ) {
        self.configuration = configuration
        self.fastForwardPull = fastForwardPull
        self.policy = policy
    }
}

extension RepoAgent {
    /// Construct + start the ADR 0068 scheduler for this agent's
    /// repo. Called from `start()`; the returned scheduler is stopped
    /// in `stop()`.
    static func startAutoSyncScheduler(
        _ startup: AutoSyncStartup,
        runner: Runner,
        gitDir: URL?
    ) async -> AutoSyncScheduler {
        let scheduler = AutoSyncScheduler(
            configuration: startup.configuration,
            policy: startup.policy,
            job: makeAutoSyncJob(
                runner: runner,
                gitDir: gitDir,
                fastForwardPull: startup.fastForwardPull
            )
        )
        await scheduler.start()
        return scheduler
    }

    /// The scheduler job: fetch, then (when enabled and no git
    /// operation is mid-flight per ADR 0056) the fast-forward pass.
    /// Errors are swallowed by design — an offline tick is "try again
    /// next tick", and ADR 0064's unreachable-remote backoff layers
    /// here later.
    private static func makeAutoSyncJob(
        runner: Runner,
        gitDir: URL?,
        fastForwardPull: Bool
    ) -> @Sendable () async -> Void {
        {
            let sync = SyncOps(runner: runner)
            do {
                try await sync.fetchAll()
                guard fastForwardPull else { return }
                if let gitDir, GitMetadataPaths.gitOperationInFlight(in: gitDir) {
                    return
                }
                _ = try await sync.fastForwardLocalBranches()
            } catch {
                // Offline / auth failure / transient lock: next tick
                // retries. RunnerLog (when attached) already recorded
                // the failing invocation for the Commands panel.
            }
        }
    }
}
