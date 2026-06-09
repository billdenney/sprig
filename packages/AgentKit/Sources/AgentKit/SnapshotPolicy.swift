// SnapshotPolicy.swift
//
// ADR 0033 snapshot-housekeeping policy for `RepoAgent`. Split out of
// RepoAgent.swift to stay under SwiftLint's file_length cap.

import Foundation

/// Policy for ADR 0033 snapshot housekeeping. Per the ADR amendment,
/// the agent runs a single TTL-based prune on startup so old
/// `refs/sprig/snapshots/...` refs don't accumulate forever. Each
/// agent host (macOS LaunchAgent, Windows Service, sprigctl) picks a
/// policy at construction; the default mirrors the ADR's "30 days"
/// recommendation.
public struct SnapshotPolicy: Equatable, Hashable, Sendable {
    /// Whether to run a TTL prune on `RepoAgent.start()`. Tests
    /// commonly disable this to keep snapshots they wrote in setup
    /// from disappearing under them; production hosts should leave
    /// it at the default.
    public var pruneOnStartup: Bool

    /// Snapshots whose timestamp is older than `now - ttl` are
    /// candidates for the startup prune.
    public var ttl: TimeInterval

    public init(pruneOnStartup: Bool, ttl: TimeInterval) {
        self.pruneOnStartup = pruneOnStartup
        self.ttl = ttl
    }

    /// 30 days, matching ADR 0033's recommendation.
    public static let defaultTTL: TimeInterval = 30 * 86400

    /// Default production policy: prune on startup, 30-day TTL.
    public static let `default` = SnapshotPolicy(pruneOnStartup: true, ttl: defaultTTL)

    /// Tests / repos where the caller manages snapshots manually.
    public static let disabled = SnapshotPolicy(pruneOnStartup: false, ttl: defaultTTL)
}
