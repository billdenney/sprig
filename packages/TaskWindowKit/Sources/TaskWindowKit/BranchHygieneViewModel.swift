// BranchHygieneViewModel.swift
//
// ADR 0073 — the portable engine behind the "Clean up branches"
// affordance (beginner-affordances item 2.4): after a fetch prunes a
// deleted remote branch, offer "this branch was merged on the server
// — clean it up?" instead of letting the local branch list become a
// junk drawer.
//
// Tier 1, portable. Shells bind to ``stale`` and ``state``; the
// banner copy comes from `UIKitShared.StatusVocabulary` (ADR 0072).
//
// Safety pairing (ADR 0033 via SafetyKit):
//   - ``cleanUp(_:)`` is the safe verb: only branches classified
//     `safeToDelete` (tip reachable from the remote default branch),
//     executed with `git branch -d` so git's own merged-check is a
//     second net. Low tier — no snapshot.
//   - ``cleanUpKeepingSafetyCopy(_:)`` is the medium-tier verb for
//     branches with unpushed commits: consults
//     `DestructiveOpTier.tier(for: SnapshotRefName.opBranchDelete)`,
//     wraps `git branch -D` in `SnapshotWriter.withSnapshot` pointing
//     at the branch tip, and reports the snapshot ref so the UI's
//     undo banner (24 h per ADR 0033) can restore it.

import Foundation
import GitCore
import SafetyKit

/// View model for the branch-cleanup affordance. Construct with the
/// repo's runner; ``refresh()`` populates ``stale``; the two cleanup
/// verbs delete with tier-appropriate safety.
public actor BranchHygieneViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL

    /// Stale branches from the latest ``refresh()``, newest detection
    /// first as returned by the engine (for-each-ref order).
    public private(set) var stale: [StaleBranch] = []

    /// Lifecycle of the latest refresh/cleanup. Success payload is
    /// the affected branch name (or "" for refresh).
    public private(set) var state: TaskWindowState<String> = .idle

    /// Snapshot ref written by the most recent
    /// ``cleanUpKeepingSafetyCopy(_:)``, for the undo banner.
    public private(set) var lastSafetyCopy: SnapshotRefName?

    private let runner: Runner
    private let hygiene: BranchHygiene
    private let snapshots: SnapshotWriter

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        self.runner = runner
        hygiene = BranchHygiene(runner: runner)
        snapshots = SnapshotWriter(runner: runner)
    }

    /// Re-detect stale branches (upstream gone, classified against
    /// the remote default branch). Quiet (empty) when no baseline
    /// remote default exists.
    public func refresh() async {
        do {
            stale = try await hygiene.staleBranches()
            state = .success("")
        } catch {
            stale = []
            state = .failure(.init(from: error))
        }
    }

    /// Delete a `safeToDelete` stale branch. Rejects (validation
    /// failure, no spawn) when the branch isn't in the current
    /// ``stale`` list or isn't classified safe — the UI should route
    /// those to ``cleanUpKeepingSafetyCopy(_:)``.
    ///
    /// Uses `git branch -D`, not `-d`: the safety proof here is the
    /// engine's `merge-base --is-ancestor <branch> <remote-default>`
    /// classification. `-d`'s own merged-check is calibrated against
    /// **HEAD**, which false-refuses the canonical 2.4 scenario —
    /// the server merged the branch but the local default branch
    /// hasn't pulled that merge yet.
    public func cleanUp(_ name: String) async {
        guard let candidate = stale.first(where: { $0.name == name }) else {
            state = .failure(.init(description: TaskWindowVocabulary.notInStaleList(name)))
            return
        }
        guard candidate.safeToDelete else {
            state = .failure(.init(description: TaskWindowVocabulary.useSafetyCopyCleanup(
                name,
                unpushed: candidate.unpushedCommitCount
            )))
            return
        }
        do {
            try await apply(outcome: hygiene.forceDeleteBranch(named: name), name: name)
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Delete a stale branch that still has unpushed commits —
    /// ADR 0033 medium tier: snapshot the tip under
    /// `refs/sprig/snapshots/…/branch-delete`, then `git branch -D`.
    /// The snapshot ref lands in ``lastSafetyCopy`` for the undo
    /// banner ("restore" = create the branch back at that ref).
    public func cleanUpKeepingSafetyCopy(_ name: String) async {
        guard let candidate = stale.first(where: { $0.name == name }) else {
            state = .failure(.init(description: TaskWindowVocabulary.notInStaleList(name)))
            return
        }
        if candidate.isCurrent {
            state = .failure(.init(description: TaskWindowVocabulary.switchAwayBeforeCleanup(name)))
            return
        }
        let tier = DestructiveOpTier.tier(for: SnapshotRefName.opBranchDelete)
        do {
            if tier?.requiresSnapshot == true {
                // Equivalent to `SnapshotWriter.withSnapshot` (create →
                // run; the snapshot persists whatever happens next) —
                // spelled as the two primitives because an actor-state-
                // mutating closure can't cross into the Sendable writer
                // under Swift 6 region isolation.
                let snapshot = try await snapshots.createSnapshot(
                    op: SnapshotRefName.opBranchDelete,
                    target: candidate.sha
                )
                lastSafetyCopy = snapshot
                try await apply(outcome: hygiene.forceDeleteBranch(named: name), name: name)
            } else {
                try await apply(outcome: hygiene.forceDeleteBranch(named: name), name: name)
            }
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Reset operation state (keeps the stale list).
    public func reset() {
        state = .idle
    }

    // MARK: - Internals

    private func apply(outcome: BranchDeleteOutcome, name: String) async throws {
        switch outcome {
        case .deleted:
            stale.removeAll { $0.name == name }
            state = .success(name)
        case .refusedNotMerged:
            state = .failure(.init(description: TaskWindowVocabulary.refusedNotFullyMerged(name)))
        case .refusedCheckedOut:
            state = .failure(.init(description: TaskWindowVocabulary.checkedOutSwitchAway(name)))
        case let .failed(reason):
            state = .failure(.init(description: reason))
        }
    }
}
