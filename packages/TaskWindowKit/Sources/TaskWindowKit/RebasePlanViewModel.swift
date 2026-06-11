// RebasePlanViewModel.swift
//
// ADR 0083 — the portable engine behind the Rebase task window's
// drag-reorder/fold/drop list (M5; ADR 0051's stacked workflows
// build on the same engine). Shells bind ``commits`` (oldest first,
// todo order — render reversed for newest-on-top lists), ``state``,
// and ``lastSafetyCopy``.
//
// Safety pairing (ADR 0033 via SafetyKit): an ADR 0033 medium-tier
// snapshot is minted at the pre-plan tip under the existing
// `rebase` op tag before anything replays. Two undo paths exist by
// design and are both pinned: a PARKED conflicted replay aborts via
// git's own `rebase --abort` (the resolver surface owns that), and
// a COMPLETED plan restores via Recover's standard reset path to
// the snapshot.

import Foundation
import GitCore
import SafetyKit

/// View model for the Rebase task window.
public actor RebasePlanViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL

    /// The rewritable range, oldest first (todo order).
    public private(set) var commits: [UnpushedCommit] = []

    /// Lifecycle of the latest operation. Success payload is the new
    /// tip's SHA (or "" for refresh).
    public private(set) var state: TaskWindowState<String> = .idle

    /// Conflicted paths when the latest plan parked mid-replay; the
    /// Conflicts surface owns continuation.
    public private(set) var conflictedPathCount = 0

    /// Snapshot ref written before the most recent plan, for the
    /// undo banner.
    public private(set) var lastSafetyCopy: SnapshotRefName?

    private let plans: RebasePlanOps
    private let snapshots: SnapshotWriter

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        plans = RebasePlanOps(runner: runner)
        snapshots = SnapshotWriter(runner: runner)
    }

    /// Re-read the rewritable range.
    public func refresh() async {
        do {
            commits = try await plans.unpushedCommits()
            state = .success("")
        } catch {
            commits = []
            state = .failure(.init(from: error))
        }
    }

    /// Execute a reorder/fold/drop plan over ``commits``.
    public func apply(_ plan: [RebaseStep]) async {
        if case .busy = state { return }
        guard !commits.isEmpty else {
            state = .failure(.init(description: TaskWindowVocabulary.nothingToRebase))
            return
        }
        state = .busy(progress: nil)
        conflictedPathCount = 0
        do {
            if DestructiveOpTier.tier(for: SnapshotRefName.opRebase)?.requiresSnapshot == true {
                lastSafetyCopy = try await snapshots.createSnapshot(
                    op: SnapshotRefName.opRebase
                )
            }
            try await apply(outcome: plans.apply(plan))
            await refreshKeepingState()
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Reset operation state (keeps the commit list).
    public func reset() {
        state = .idle
    }

    // MARK: - Internals

    private func apply(outcome: RebasePlanOutcome) {
        switch outcome {
        case let .completed(newTip):
            state = .success(newTip)
        case let .conflicted(pathCount):
            conflictedPathCount = pathCount
            state = .failure(.init(description: TaskWindowVocabulary.rebaseConflictHandoff))
        case .invalidPlan:
            state = .failure(.init(description: TaskWindowVocabulary.invalidRebasePlan))
        case .refusedNothingToRebase:
            state = .failure(.init(description: TaskWindowVocabulary.nothingToRebase))
        case .refusedMidstream:
            state = .failure(.init(description: TaskWindowVocabulary.historyMidstream))
        case .refusedStagedChanges:
            state = .failure(.init(description: TaskWindowVocabulary.historyStagedChanges))
        case .refusedDirtyWorktree:
            state = .failure(.init(description: TaskWindowVocabulary.rebaseDirtyWorktree))
        case .refusedDetachedHEAD:
            state = .failure(.init(description: TaskWindowVocabulary.historyDetached))
        case let .failed(reason):
            state = .failure(.init(description: reason))
        }
    }

    private func refreshKeepingState() async {
        let kept = state
        await refresh()
        if case .success = state {
            state = kept
        }
    }
}
