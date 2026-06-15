// StackRestackViewModel.swift
//
// ADR 0085 (ADR 0051 substrate) — the portable engine behind the
// "Restack" verb in the Stack Manager task window. Replay a stacked
// child branch onto its moved parent's tip. Shells bind ``state``,
// ``conflictedPathCount``, and ``lastSafetyCopy``.
//
// Restacks the CHECKED-OUT branch only (refuses otherwise). The
// snapshot the medium tier mints is a plain `refs/sprig/snapshots/…`
// ref with no branch identity, and the Recover surface restores it by
// resetting the *current* branch — so the branch being restacked must
// be the current one, or the undo would reset the wrong branch (a real
// bug caught in review). The Stack Manager UI switches to the branch
// before invoking restack.
//
// Safety pairing (ADR 0033 medium tier via SafetyKit, `restack` op
// tag): the snapshot is minted at the branch's PRE-restack tip (== HEAD,
// captured before the engine runs), only when the op actually changed
// state (`.completed`) or parked a rebase (`.conflicted`) — a refusal
// leaves the repo untouched, so nothing is recoverable and no snapshot
// is minted. On a conflict the rebase is parked (the M4 resolver owns
// `--continue`/`--abort`); HEAD stays on the restacked branch either way.

import Foundation
import GitCore
import SafetyKit

/// View model for the Restack verb.
public actor StackRestackViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL

    /// Lifecycle of the latest restack. Success payload is the
    /// child's new tip SHA.
    public private(set) var state: TaskWindowState<String> = .idle

    /// Conflicted paths when the latest restack parked mid-replay; the
    /// Conflicts surface owns continuation.
    public private(set) var conflictedPathCount = 0

    /// Snapshot ref written for the most recent state-changing
    /// restack, for the undo banner.
    public private(set) var lastSafetyCopy: SnapshotRefName?

    private let runner: Runner
    private let stacks: StackOps
    private let snapshots: SnapshotWriter

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        self.runner = runner
        stacks = StackOps(runner: runner)
        snapshots = SnapshotWriter(runner: runner)
    }

    /// Replay the CHECKED-OUT `branch` onto its recorded parent's
    /// current tip. Refuses if `branch` isn't the current branch (the
    /// snapshot/undo path resets the current branch — see the type doc).
    public func restack(branch: String) async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        conflictedPathCount = 0
        lastSafetyCopy = nil
        do {
            // A non-current branch's snapshot would undo onto the wrong
            // branch. (A detached HEAD reads nil here and is caught by
            // the engine's guard as .refusedDetachedHEAD.)
            if let current = try await currentBranch(), current != branch {
                state = .failure(.init(description: TaskWindowVocabulary.restackNotCheckedOut))
                return
            }
            let preTip = try await branchTip(branch)
            let outcome = try await stacks.restack(branch: branch)
            try await apply(outcome, preTip: preTip)
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Reset operation state.
    public func reset() {
        state = .idle
    }

    // MARK: - Internals

    private func apply(_ outcome: StackRestackOutcome, preTip: String?) async throws {
        switch outcome {
        case let .completed(newTip):
            try await snapshotIfNeeded(at: preTip)
            state = .success(newTip)
        case let .conflicted(_, pathCount):
            try await snapshotIfNeeded(at: preTip)
            conflictedPathCount = pathCount
            state = .failure(.init(description: TaskWindowVocabulary.rebaseConflictHandoff))
        default:
            state = .failure(.init(description: Self.refusalDescription(outcome)))
        }
    }

    /// Word the refusal/failure outcomes. Guard refusals reuse the
    /// history/rebase vocabulary whose semantics already match.
    private static func refusalDescription(_ outcome: StackRestackOutcome) -> String {
        switch outcome {
        case .refusedNothingToRestack: TaskWindowVocabulary.restackNothingToRestack
        case .refusedNoParentRecorded: TaskWindowVocabulary.restackNoParentRecorded
        case .refusedForkPointDiverged: TaskWindowVocabulary.restackForkPointDiverged
        case .refusedStackCycle: TaskWindowVocabulary.restackStackCycle
        case .refusedMidstream: TaskWindowVocabulary.historyMidstream
        case .refusedStagedChanges: TaskWindowVocabulary.historyStagedChanges
        case .refusedDirtyWorktree: TaskWindowVocabulary.rebaseDirtyWorktree
        case .refusedDetachedHEAD: TaskWindowVocabulary.historyDetached
        case let .failed(reason): reason
        case .completed, .conflicted: "" // handled by apply(_:); never reached
        }
    }

    private func snapshotIfNeeded(at tip: String?) async throws {
        guard let tip,
              DestructiveOpTier.tier(for: SnapshotRefName.opRestack)?.requiresSnapshot == true
        else { return }
        lastSafetyCopy = try await snapshots.createSnapshot(
            op: SnapshotRefName.opRestack,
            target: tip
        )
    }

    private func branchTip(_ branch: String) async throws -> String? {
        let result = try await runner.run(
            ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
            throwOnNonZero: false
        )
        guard result.exitCode == 0 else { return nil }
        let sha = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    private func currentBranch() async throws -> String? {
        let result = try await runner.run(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            throwOnNonZero: false
        )
        guard result.exitCode == 0 else { return nil }
        let name = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
