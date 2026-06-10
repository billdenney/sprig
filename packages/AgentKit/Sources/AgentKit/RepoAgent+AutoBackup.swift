// RepoAgent+AutoBackup.swift
//
// ADR 0075 auto-backup wiring for `RepoAgent` — mirrors the ADR 0068
// auto-sync wiring (RepoAgent+AutoSync.swift): an optional startup
// config whose scheduler the agent starts in `start()` and stops in
// `stop()`. The scheduler type is the generic AutoSyncScheduler —
// it owns *when*; the job here owns *what*.

import Foundation
import GitCore
import PlatformKit
import SafetyKit

/// ADR 0075 auto-backup wiring for one agent. When non-nil, the
/// agent periodically snapshots a dirty working tree into
/// `refs/sprig/backup/<ts>/<branch>` (tracked + untracked; HEAD,
/// index, worktree, and hooks untouched) and TTL-prunes old backups.
public struct AutoBackupStartup: Sendable {
    /// Cadence knobs. ADR 0075 default: every 30 minutes with jitter,
    /// no fire-on-start (an immediate backup at agent launch would
    /// mostly duplicate the previous session's last tick).
    public var configuration: AutoSyncConfiguration

    /// Backups older than this are pruned each tick. ADR 0075
    /// default: 7 days.
    public var ttl: TimeInterval

    /// Per-tick pause gate (ADR 0064 platform signals — backups are
    /// pure-local but still skipped in Low Power Mode etc.).
    public var policy: any SyncPolicy

    public init(
        configuration: AutoSyncConfiguration = AutoSyncConfiguration(
            interval: .seconds(30 * 60),
            jitterFraction: 0.1,
            fireOnStart: false
        ),
        ttl: TimeInterval = 7 * 86400,
        policy: any SyncPolicy = AlwaysAllowSyncPolicy()
    ) {
        self.configuration = configuration
        self.ttl = ttl
        self.policy = policy
    }
}

extension RepoAgent {
    /// Construct + start the ADR 0075 scheduler for this agent's
    /// repo. Called from `start()`; stopped in `stop()`.
    static func startAutoBackupScheduler(
        _ startup: AutoBackupStartup,
        runner: Runner
    ) async -> AutoSyncScheduler {
        let scheduler = AutoSyncScheduler(
            configuration: startup.configuration,
            policy: startup.policy,
            job: makeAutoBackupJob(runner: runner, ttl: startup.ttl)
        )
        await scheduler.start()
        return scheduler
    }

    /// The tick job: back up if dirty, prune by TTL. Errors swallowed
    /// by design — backup is best-effort insurance and the next tick
    /// retries; RunnerLog (when attached) records failing invocations.
    private static func makeAutoBackupJob(
        runner: Runner,
        ttl: TimeInterval
    ) -> @Sendable () async -> Void {
        {
            let backup = WorktreeBackup(runner: runner)
            do {
                _ = try await backup.createBackupIfDirty()
                _ = try await backup.prune(olderThan: Date().addingTimeInterval(-ttl))
            } catch {
                // Best-effort; next tick retries.
            }
        }
    }
}
