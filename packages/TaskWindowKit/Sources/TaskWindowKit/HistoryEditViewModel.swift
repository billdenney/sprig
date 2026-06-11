// HistoryEditViewModel.swift
//
// ADR 0082 — the portable engine behind the "Reword Last Commit"
// and "Squash Commits" task windows (master plan §10). Shells bind
// ``unpushedCount`` (the squash slider's upper bound), ``lastSubject``
// (the reword field's prefill), ``state``, and ``lastSafetyCopy``.
//
// Guard order, by design:
//   1. VM pre-guards from its own refreshed counts — empty message,
//      count bounds, nothing-unpushed — are worded validation
//      failures and spawn nothing.
//   2. The ADR 0033 medium-tier snapshot is taken at the pre-edit
//      HEAD. Restoring it is Recover's standard `reset --hard` path
//      — one click undoes the rewrite (round-trip test-pinned).
//   3. The engine re-checks every guard fail-closed (shared /
//      midstream / staged / detached); an engine refusal after the
//      snapshot is the rare race case, worded all the same. The
//      orphan snapshot it leaves is harmless and TTL-pruned.

import Foundation
import GitCore
import SafetyKit

/// View model for the history-edit task windows.
public actor HistoryEditViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL

    /// Commits on HEAD that no remote-tracking ref contains — the
    /// rewritable depth (and the squash count's upper bound).
    public private(set) var unpushedCount = 0

    /// HEAD's subject line, for prefilling the reword field.
    public private(set) var lastSubject = ""

    /// Lifecycle of the latest operation. Success payload is the new
    /// tip's SHA.
    public private(set) var state: TaskWindowState<String> = .idle

    /// Snapshot ref written before the most recent edit, for the
    /// undo banner (restore = Recover's reset path to the old tip).
    public private(set) var lastSafetyCopy: SnapshotRefName?

    private let runner: Runner
    private let history: HistoryOps
    private let snapshots: SnapshotWriter

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        self.runner = runner
        history = HistoryOps(runner: runner)
        snapshots = SnapshotWriter(runner: runner)
    }

    /// Re-read the rewritable depth and HEAD's subject. Quiet zeros
    /// on an unborn HEAD.
    public func refresh() async {
        do {
            let count = try await runner.run(
                ["rev-list", "--count", "HEAD", "--not", "--remotes"],
                throwOnNonZero: false
            )
            unpushedCount = count.exitCode == 0
                ? Int(count.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                : 0
            let subject = try await runner.run(
                ["log", "-1", "--format=%s"],
                throwOnNonZero: false
            )
            lastSubject = subject.exitCode == 0
                ? subject.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            state = .success("")
        } catch {
            unpushedCount = 0
            lastSubject = ""
            state = .failure(.init(from: error))
        }
    }

    /// Replace HEAD's message (and nothing else).
    public func reword(message: String) async {
        if case .busy = state { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failure(.init(description: TaskWindowVocabulary.enterCommitSubject))
            return
        }
        guard unpushedCount > 0 else {
            state = .failure(.init(description: TaskWindowVocabulary.historyShared))
            return
        }
        state = .busy(progress: nil)
        do {
            try await takeSafetyCopy(op: SnapshotRefName.opReword)
            try await apply(rewordOutcome: history.rewordLastCommit(message: trimmed))
            await refreshKeepingState()
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Combine the last `count` commits into one.
    public func squash(count: Int, message: String) async {
        if case .busy = state { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failure(.init(description: TaskWindowVocabulary.enterCommitSubject))
            return
        }
        guard count >= 2 else {
            state = .failure(.init(description: TaskWindowVocabulary.historyNeedTwo))
            return
        }
        guard count <= unpushedCount else {
            state = .failure(.init(description: TaskWindowVocabulary.historyShared))
            return
        }
        state = .busy(progress: nil)
        do {
            try await takeSafetyCopy(op: SnapshotRefName.opSquash)
            try await apply(squashOutcome: history.squashLast(count, message: trimmed))
            await refreshKeepingState()
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Reset operation state (keeps the counts).
    public func reset() {
        state = .idle
    }

    // MARK: - Internals

    private func takeSafetyCopy(op: String) async throws {
        if DestructiveOpTier.tier(for: op)?.requiresSnapshot == true {
            lastSafetyCopy = try await snapshots.createSnapshot(op: op)
        }
    }

    private func apply(rewordOutcome outcome: RewordOutcome) {
        switch outcome {
        case let .reworded(newSHA):
            state = .success(newSHA)
        case .refusedShared:
            state = .failure(.init(description: TaskWindowVocabulary.historyShared))
        case .refusedMidstream:
            state = .failure(.init(description: TaskWindowVocabulary.historyMidstream))
        case .refusedStagedChanges:
            state = .failure(.init(description: TaskWindowVocabulary.historyStagedChanges))
        case .refusedNoCommits:
            state = .failure(.init(description: TaskWindowVocabulary.historyNoCommits))
        case .refusedDetachedHEAD:
            state = .failure(.init(description: TaskWindowVocabulary.historyDetached))
        }
    }

    private func apply(squashOutcome outcome: SquashOutcome) {
        switch outcome {
        case let .squashed(newSHA, _):
            state = .success(newSHA)
        case .refusedShared:
            state = .failure(.init(description: TaskWindowVocabulary.historyShared))
        case .refusedMidstream:
            state = .failure(.init(description: TaskWindowVocabulary.historyMidstream))
        case .refusedStagedChanges:
            state = .failure(.init(description: TaskWindowVocabulary.historyStagedChanges))
        case .refusedDetachedHEAD:
            state = .failure(.init(description: TaskWindowVocabulary.historyDetached))
        case .refusedNeedAtLeastTwo:
            state = .failure(.init(description: TaskWindowVocabulary.historyNeedTwo))
        case .refusedNotEnoughHistory:
            state = .failure(.init(description: TaskWindowVocabulary.historyNotEnoughHistory))
        }
    }

    /// Re-read counts after a successful edit without clobbering the
    /// terminal outcome the UI is presenting.
    private func refreshKeepingState() async {
        let kept = state
        await refresh()
        if case .success = state {
            state = kept
        }
    }
}

// MARK: - Revert (ADR 0084)

extension HistoryEditViewModel {
    /// Forward-fix `sha` — a NEW commit with the opposite change, so
    /// it is the safe verb for already-shared commits. ADR 0033
    /// medium tier (`revert` op tag): the pre-revert tip is
    /// snapshotted first, so the revert itself is one Recover
    /// restore away (round-trip test-pinned).
    public func revert(sha: String) async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        do {
            try await takeSafetyCopy(op: SnapshotRefName.opRevert)
            try await apply(revertOutcome: history.revert(sha))
            await refreshKeepingState()
        } catch {
            state = .failure(.init(from: error))
        }
    }

    private func apply(revertOutcome outcome: RevertOutcome) {
        switch outcome {
        case let .reverted(newSHA):
            state = .success(newSHA)
        case .conflicted:
            state = .failure(.init(description: TaskWindowVocabulary.revertConflicted))
        case .refusedUnknownCommit:
            state = .failure(.init(description: TaskWindowVocabulary.revertUnknownCommit))
        case .refusedMergeCommit:
            state = .failure(.init(description: TaskWindowVocabulary.revertMergeCommit))
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
}
