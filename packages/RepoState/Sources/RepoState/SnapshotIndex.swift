// SnapshotIndex.swift
//
// Slice S3 of ADR 0033 — the *read* side of the snapshot machinery.
// `SafetyKit.SnapshotWriter` (S2) creates `refs/sprig/snapshots/...`
// refs; this actor lists / queries them on behalf of the Recover task
// window, the `sprigctl recover --list` CLI subcommand, and the TTL
// pruner that the next slice will add.
//
// "Without spawning git per query" (per ADR 0033's amendment): one
// `git for-each-ref` invocation populates a cached list, and queries
// (`list()`, `snapshots(olderThan:)`) read the cache directly. Callers
// `refresh()` whenever they need fresh data — typically once when a
// view opens, plus opportunistically after a destructive op completes.
//
// Lives in RepoState (not SafetyKit) per the ADR's split: SafetyKit
// owns *writing* snapshots (a precondition for destructive ops);
// RepoState owns *reading* / observing them (it's part of "what's the
// state of this repo").

import Foundation
import GitCore
import SafetyKit

/// One entry in the snapshot index — the parsed
/// ``SafetyKit/SnapshotRefName`` plus the commit SHA the ref points at.
public struct Snapshot: Equatable, Hashable, Sendable {
    /// The decomposed ref name (timestamp + op).
    public let name: SnapshotRefName

    /// The commit SHA the snapshot ref points at. Whatever `git
    /// for-each-ref --format=%(objectname)` reported — typically a
    /// 40-char SHA-1 hex (or 64 chars on a SHA-256 repo).
    public let sha: String

    public init(name: SnapshotRefName, sha: String) {
        self.name = name
        self.sha = sha
    }
}

/// Lists / queries snapshot refs for one repo.
///
/// **Cache lifecycle.** Construction is cheap (no git invocation);
/// the cache starts empty. Call ``refresh()`` to populate it via a
/// single `git for-each-ref refs/sprig/snapshots/` invocation. Queries
/// (``list()``, ``snapshots(olderThan:)``, ``count``) return the cached
/// state — no further git invocation. Callers re-call ``refresh()``
/// whenever they need fresh data; the actor's serial-execution
/// guarantee makes concurrent refresh+query safe.
///
/// **Per-repo scope.** Construct one `SnapshotIndex` per repo whose
/// `Runner` is configured for that repo's working directory. Sharing
/// across repos doesn't make sense — the snapshot refs are per-repo by
/// definition.
public actor SnapshotIndex {
    private let runner: Runner
    private var cached: [Snapshot] = []
    private var lastRefreshAt: Date?

    public init(runner: Runner) {
        self.runner = runner
    }

    /// Re-run `git for-each-ref` and replace the cached list. Newest
    /// snapshots first.
    ///
    /// Throws ``GitCore/GitError`` from the underlying invocation.
    /// Malformed refs under `refs/sprig/snapshots/` (e.g. a manually
    /// added ref that doesn't match ``SafetyKit/SnapshotRefName``'s
    /// shape) are silently skipped — the index represents Sprig's
    /// snapshots, not arbitrary refs that happen to share the prefix.
    public func refresh() async throws {
        let output = try await runner.run([
            "for-each-ref",
            "--format=%(refname) %(objectname)",
            SnapshotRefName.prefix
        ])
        let snapshots = SnapshotIndex.parse(output.stdoutString)
        cached = snapshots.sorted { $0.name.timestamp > $1.name.timestamp }
        lastRefreshAt = Date()
    }

    /// Snapshots from the cache, newest first. Returns `[]` if
    /// ``refresh()`` hasn't been called yet (or the repo has no
    /// snapshots).
    public func list() -> [Snapshot] {
        cached
    }

    /// Snapshots whose timestamp is strictly older than `cutoff`.
    /// The TTL pruner (next slice) consumes this to find candidates
    /// for deletion.
    public func snapshots(olderThan cutoff: Date) -> [Snapshot] {
        cached.filter { $0.name.timestamp < cutoff }
    }

    /// Count of snapshots in the cache. Useful for the
    /// "<N> older snapshots auto-pruned" footer the Recover window
    /// surfaces (per ADR 0033's amendment).
    public var count: Int {
        cached.count
    }

    /// When ``refresh()`` last completed; nil before the first
    /// successful refresh.
    public var lastRefresh: Date? {
        lastRefreshAt
    }

    // MARK: - Parsing

    /// `git for-each-ref --format=%(refname) %(objectname)` output is
    /// one line per ref, e.g.
    ///
    ///     refs/sprig/snapshots/20260506T031234Z/merge abc123def456...
    ///
    /// Lines that don't have exactly two space-separated fields are
    /// skipped; lines whose first field isn't a valid
    /// `SnapshotRefName` are skipped (defends against manually-written
    /// refs with the same prefix).
    static func parse(_ stdout: String) -> [Snapshot] {
        var result: [Snapshot] = []
        stdout.enumerateLines { line, _ in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return }
            let refName = String(parts[0])
            let sha = String(parts[1])
            guard let name = SnapshotRefName.parse(refName) else { return }
            result.append(Snapshot(name: name, sha: sha))
        }
        return result
    }
}
