// AgentReviewViewModel.swift
//
// ADR 0088 — the portable engine behind the "Review external changes…"
// task window. When an outside process (a terminal, an AI coding agent,
// a teammate's tooling) commits to a worktree, this VM surfaces those
// externally-authored commits as a reviewable set and offers safe verbs
// over them:
//
//   * **Review** — ``refresh()`` lists the external commits (via
//     `GitCore.ExternalChangeDetector`) plus a per-commit diff, and
//     reports whether HEAD itself was moved from outside.
//   * **Stage / unstage selectively** — move working-tree changes into
//     and out of the index, including ADR 0061 region staging.
//   * **Split a commit** — ``splitCommit(_:)`` snapshots HEAD, then
//     `reset --soft`s onto the commit's parent so its changes sit in the
//     index for the user to region-stage into separate commits. NEVER a
//     silent rewrite: it mints a snapshot first and the soft reset keeps
//     every change in the index (nothing is discarded).
//   * **Undo** — ``undo()`` restores the pre-split state through the
//     real Recover path (`reset --hard <snapshot>` with the same
//     insurance refs the Recover window takes).
//
// Safe-by-default: review and staging touch only the index (reversible,
// no snapshot). The one history-rewriting action — split — is
// user-initiated, tiered-confirmed by the caller (medium tier), and
// snapshots first.
//
// Tier 1, portable. Per ADR 0048 the VM lives here; the per-OS shells
// bind ``report``, ``commitDiffs``, ``state``, and ``lastSafetyCopy``.

import Foundation
import GitCore
import SafetyKit

/// What the latest agent-review operation produced.
public enum AgentReviewOutcome: Sendable, Equatable {
    /// ``AgentReviewViewModel/refresh()`` completed; the report has this
    /// many external commits and this HEAD-movement signal.
    case reviewed(externalCommitCount: Int, headMoved: Bool)
    /// A working-tree change was staged or unstaged; the payload is the
    /// path acted on.
    case staged(String)
    case unstaged(String)
    /// A region selection was staged into the index (ADR 0061).
    case stagedSelection
    /// A commit was split: HEAD was soft-reset onto its parent so the
    /// commit's changes sit in the index. The payload is the commit SHA
    /// that was split; `snapshot` is the pre-split safety copy.
    case splitCommit(sha: String, snapshot: SnapshotRefName)
    /// A split (or other snapshotted action) was undone via the Recover
    /// path. `restoredTo` is the SHA HEAD was reset to.
    case undone(restoredTo: String)
}

/// View model for the "Review external changes…" task window (ADR 0088).
///
/// **Actor-isolated.** All mutable state lives behind the actor.
///
/// **Lifecycle.** Construct with the repo URL + Runner. ``refresh()``
/// populates ``report`` and ``commitDiffs``. The UI calls ``stage(_:)``
/// / ``unstage(_:)`` / ``stageSelection(in:selection:)`` to curate the
/// index, ``splitCommit(_:)`` to open a commit for re-staging, and
/// ``undo()`` to roll a split back through the Recover path.
public actor AgentReviewViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL

    /// The latest external-change picture: the reviewable commits + the
    /// HEAD-movement signal. Empty until the first ``refresh()``.
    public private(set) var report: ExternalChangeReport =
        .init(commits: [], headMovement: .unchanged)

    /// Per-external-commit unified diff (`git show`), keyed by commit
    /// SHA. Populated by ``refresh()`` so the UI can render each
    /// reviewable commit without a second round-trip.
    public private(set) var commitDiffs: [String: String] = [:]

    /// Lifecycle of the latest review / stage / split / undo call.
    public private(set) var state: TaskWindowState<AgentReviewOutcome> = .idle

    /// Snapshot ref written for the most recent split, for the undo
    /// banner and ``undo()``. Cleared by ``refresh()`` and by a
    /// successful ``undo()``.
    public private(set) var lastSafetyCopy: SnapshotRefName?

    private let runner: Runner
    private let detector: ExternalChangeDetector
    private let snapshots: SnapshotWriter
    private let recover: RecoverViewModel

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        self.runner = runner
        detector = ExternalChangeDetector(runner: runner)
        snapshots = SnapshotWriter(runner: runner)
        recover = RecoverViewModel(repoURL: repoURL, runner: runner)
    }

    // MARK: - Review

    /// Re-scan the worktree for externally-authored change and fetch a
    /// diff for each external commit. Failures land in ``state`` and
    /// leave the report empty so the UI never shows stale data.
    public func refresh() async {
        do {
            let report = try await detector.report()
            var diffs: [String: String] = [:]
            for commit in report.commits {
                diffs[commit.sha] = try await commitDiff(commit.sha)
            }
            self.report = report
            commitDiffs = diffs
            lastSafetyCopy = nil
            let headMoved = if case .movedExternally = report.headMovement { true } else { false }
            state = .success(.reviewed(
                externalCommitCount: report.commits.count,
                headMoved: headMoved
            ))
        } catch {
            report = ExternalChangeReport(commits: [], headMovement: .unchanged)
            commitDiffs = [:]
            state = .failure(.init(from: error))
        }
    }

    // MARK: - Stage / unstage

    /// Run `git add <path>` — stage a working-tree change for review.
    public func stage(_ path: String) async {
        await runIndexMutation(["add", path], outcome: .staged(path))
    }

    /// Run `git restore --staged <path>` — unstage without discarding
    /// the worktree change.
    public func unstage(_ path: String) async {
        await runIndexMutation(["restore", "--staged", path], outcome: .unstaged(path))
    }

    /// Region staging (ADR 0061): stage exactly `selection` within
    /// `diff` (the unstaged `git diff` the UI rendered). Index-only and
    /// reversible (`git restore --staged`), so — like ``stage(_:)`` — it
    /// mints no snapshot.
    public func stageSelection(in diff: String, selection: Range<String.Index>) async {
        let sliced: SlicedPatch
        do {
            sliced = try DiffPatchSlicer.slice(diff: diff, selection: selection)
        } catch DiffPatchSlicerError.cannotSplitEndOfFileChange {
            state = .failure(.init(description: TaskWindowVocabulary.cannotSplitEndOfFile))
            return
        } catch {
            state = .failure(.init(description: TaskWindowVocabulary.selectionHasNoChange))
            return
        }
        await runIndexMutation(
            ["apply", "--cached", "--recount", "-"],
            outcome: .stagedSelection,
            stdin: Data(sliced.patch.utf8)
        )
    }

    // MARK: - Split

    /// Split an externally-authored commit: snapshot pre-split HEAD,
    /// then `reset --soft <sha>^` so the commit's changes sit in the
    /// index for the user to region-stage into separate commits.
    ///
    /// Snapshot-first and non-destructive: the soft reset moves only the
    /// branch ref (HEAD), leaving the index and working tree exactly as
    /// the commit left them — nothing is discarded, and the pre-split
    /// snapshot makes the whole thing undoable via ``undo()``.
    ///
    /// Pre-flights (no snapshot, no spawn on failure):
    ///   - the commit must be the current tip (`HEAD`) — splitting a
    ///     commit buried in history is a rebase, not in scope here.
    ///   - the commit must have exactly one parent (a root or merge
    ///     commit has no single parent to soft-reset onto).
    ///   - the working tree + index must be clean, so the split's index
    ///     contents are exactly the commit's changes and nothing else.
    public func splitCommit(_ sha: String) async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        lastSafetyCopy = nil
        do {
            guard try await isHeadCommit(sha) else {
                state = .failure(.init(description: TaskWindowVocabulary.agentReviewSplitNotTip))
                return
            }
            guard let parent = try await singleParent(of: sha) else {
                state = .failure(.init(description: TaskWindowVocabulary.agentReviewSplitNoParent))
                return
            }
            guard try await isWorkingTreeClean() else {
                state = .failure(.init(description: TaskWindowVocabulary.agentReviewSplitDirty))
                return
            }
            // Medium tier per DestructiveOpTier; mint the snapshot at
            // pre-split HEAD BEFORE the reset so the whole split is one
            // undoable unit. Expose it via `lastSafetyCopy` *before* the
            // reset too: the snapshot ref is already persisted to git, so
            // if `reset --soft` throws, undo() can still find it (a
            // no-op `reset --hard` back onto the unmoved HEAD) instead of
            // orphaning the snapshot to the separate Recover window.
            let snapshot = try await snapshots.createSnapshot(op: SnapshotRefName.opSplit)
            lastSafetyCopy = snapshot
            _ = try await runner.run(["reset", "--soft", parent])
            state = .success(.splitCommit(sha: sha, snapshot: snapshot))
        } catch {
            state = .failure(.init(from: error))
        }
    }

    // MARK: - Undo

    /// Undo the most recent split through the real Recover path: restore
    /// the pre-split snapshot via the same fail-closed `reset --hard`
    /// (with insurance refs) the Recover window uses. A no-op failure
    /// when there's nothing to undo.
    public func undo() async {
        if case .busy = state { return }
        guard let snapshot = lastSafetyCopy else {
            state = .failure(.init(description: TaskWindowVocabulary.agentReviewNothingToUndo))
            return
        }
        state = .busy(progress: nil)
        await recover.restoreSnapshot(snapshot.refName)
        switch await recover.state {
        case .success:
            do {
                let head = try await runner.run(["rev-parse", "HEAD"]).stdoutString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lastSafetyCopy = nil
                state = .success(.undone(restoredTo: head))
            } catch {
                state = .failure(.init(from: error))
            }
        case let .failure(failure):
            state = .failure(.init(
                description: failure.description,
                underlyingTypeName: failure.underlyingTypeName
            ))
        case .idle, .busy:
            state = .failure(.init(description: TaskWindowVocabulary.agentReviewNothingToUndo))
        }
    }

    /// Reset operation state. Preserves the report + diffs.
    public func reset() {
        state = .idle
    }

    // MARK: - Internals

    private func commitDiff(_ sha: String) async throws -> String {
        try await runner.run([
            "show",
            "--format=", // body handled by the commit metadata already in the report
            sha
        ]).stdoutString
    }

    private func isHeadCommit(_ sha: String) async throws -> Bool {
        let head = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = try await runner.run(["rev-parse", "--verify", "\(sha)^{commit}"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !head.isEmpty && head == target
    }

    /// The sole parent of `sha`, or nil for a root commit (no parent) or
    /// a merge commit (more than one).
    private func singleParent(of sha: String) async throws -> String? {
        let parentsField = try await runner.run(["rev-list", "--parents", "-n", "1", sha])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = parentsField.split(separator: " ").map(String.init)
        // `<sha> <parent1> [<parent2> …]`; exactly one parent → 2 tokens.
        guard tokens.count == 2 else { return nil }
        return tokens[1]
    }

    private func isWorkingTreeClean() async throws -> Bool {
        try await runner.run(["status", "--porcelain", "-z"]).stdout.isEmpty
    }

    private func runIndexMutation(
        _ argv: [String],
        outcome: AgentReviewOutcome,
        stdin: Data? = nil
    ) async {
        do {
            _ = try await runner.run(argv, stdin: stdin)
            state = .success(outcome)
        } catch {
            state = .failure(.init(from: error))
        }
    }
}
