// StatusViewModel.swift
//
// ADR 0064's Status task-window surface, portable half: the per-repo
// dashboard answering "where does this repo stand?" in one refresh —
// working-tree counts, every branch's upstream relationship, whether
// a merge/rebase is parked mid-flight, and how much safety net
// exists (ADR 0033 snapshots + ADR 0075 backups). Plus the ADR 0064
// "Fetch now" affordance: a one-shot fetch for when hourly isn't
// soon enough.
//
// Composes existing engine primitives only — one porcelain spawn,
// one for-each-ref pass per namespace, one rev-parse for the
// mid-operation probe. No new git plumbing.
//
// Tier 1, portable. Shells bind to ``state``'s summary; copy comes
// from `UIKitShared.StatusVocabulary` (ADR 0072).

import Foundation
import GitCore
import RepoState
import SafetyKit

/// Everything the Status window shows, from one ``refresh()``.
public struct RepoStatusSummary: Sendable, Equatable {
    // Working-tree counts (shared classifier — can never disagree
    // with the CommitComposer's partition).
    public var stagedCount: Int
    public var unstagedCount: Int
    public var untrackedCount: Int
    public var conflictedCount: Int

    /// Porcelain `--branch` headers (oid/head/upstream); nil when the
    /// parse produced no header block.
    public var branch: BranchInfo?

    /// Every local branch's upstream relationship, engine order
    /// (`for-each-ref refs/heads/`).
    public var branches: [BranchSyncState]

    /// `.none` when no merge/rebase/cherry-pick/revert/am is parked.
    public var midOperation: MidstreamOperation

    /// ADR 0033 snapshot-ref count.
    public var snapshotCount: Int
    /// ADR 0075 backup-ref count.
    public var backupCount: Int
    /// Timestamp of the newest safety copy across both namespaces,
    /// nil when there are none.
    public var newestSafetyCopy: Date?

    /// The checked-out branch's relationship, if any.
    public var currentBranchState: BranchSyncState? {
        branches.first(where: \.isCurrent)
    }

    public init(
        stagedCount: Int = 0,
        unstagedCount: Int = 0,
        untrackedCount: Int = 0,
        conflictedCount: Int = 0,
        branch: BranchInfo? = nil,
        branches: [BranchSyncState] = [],
        midOperation: MidstreamOperation = .none,
        snapshotCount: Int = 0,
        backupCount: Int = 0,
        newestSafetyCopy: Date? = nil
    ) {
        self.stagedCount = stagedCount
        self.unstagedCount = unstagedCount
        self.untrackedCount = untrackedCount
        self.conflictedCount = conflictedCount
        self.branch = branch
        self.branches = branches
        self.midOperation = midOperation
        self.snapshotCount = snapshotCount
        self.backupCount = backupCount
        self.newestSafetyCopy = newestSafetyCopy
    }
}

/// View model for the Status task window. ``refresh()`` builds the
/// summary; ``fetchNow()`` is ADR 0064's manual fetch.
public actor StatusViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL

    /// Lifecycle + the latest summary.
    public private(set) var state: TaskWindowState<RepoStatusSummary> = .idle

    private let runner: Runner
    private let sync: SyncOps
    private let snapshots: SnapshotIndex
    private let backups: WorktreeBackup

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        self.runner = runner
        sync = SyncOps(runner: runner)
        snapshots = SnapshotIndex(runner: runner)
        backups = WorktreeBackup(runner: runner)
    }

    /// Rebuild the whole summary. Safe to call repeatedly; the badge
    /// pipeline's change events are the natural trigger in the
    /// shells.
    public func refresh() async {
        do {
            state = try await .success(buildSummary())
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// ADR 0064's "Fetch now": one `fetch --all --prune`, then a full
    /// re-summary so behind/ahead counts reflect the fresh
    /// remote-tracking refs. A fetch failure (offline, auth) is the
    /// only `.failure`; the summary itself re-raises real repo
    /// breakage through ``refresh()``'s path.
    public func fetchNow() async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        do {
            try await sync.fetchAll()
        } catch {
            state = .failure(.init(from: error))
            return
        }
        await refresh()
    }

    private func buildSummary() async throws -> RepoStatusSummary {
        let status = try await runner.run([
            "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"
        ])
        let parsed = try PorcelainV2Parser.parse(status.stdout)
        var summary = RepoStatusSummary(branch: parsed.branch)
        for entry in parsed.entries {
            let buckets = WorkingTreeClassifier.classify(entry)
            if buckets.staged != nil { summary.stagedCount += 1 }
            if buckets.unstaged != nil { summary.unstagedCount += 1 }
            if buckets.untracked != nil { summary.untrackedCount += 1 }
            if buckets.conflicted != nil { summary.conflictedCount += 1 }
        }

        summary.branches = try await sync.branchSyncStates()
        summary.midOperation = try await MidstreamOperation.detect(
            repoURL: repoURL,
            runner: runner
        )

        try await snapshots.refresh()
        let snapshotDates = await snapshots.list().map(\.name.timestamp)
        let backupDates = try await backups.backups().map(\.ref.timestamp)
        summary.snapshotCount = snapshotDates.count
        summary.backupCount = backupDates.count
        summary.newestSafetyCopy = (snapshotDates + backupDates).max()
        return summary
    }

    /// Reset to ``TaskWindowState/idle``.
    public func reset() {
        state = .idle
    }
}
