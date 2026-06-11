// HistoryOps+Revert.swift
//
// ADR 0084 — the "Revert Changes" verb (master plan §10): undo a
// commit by creating a NEW commit with the opposite change. Unlike
// reword/squash this is additive — no history is rewritten, so it is
// the safe verb for commits that are already shared. The hazards are
// different: a revert can CONFLICT (the surrounding code moved on),
// and reverting a merge commit needs a mainline choice git can't
// infer — both are typed outcomes, not surprises.

import Foundation

/// Result of ``HistoryOps/revert(_:)``.
public enum RevertOutcome: Sendable, Equatable {
    /// A revert commit was created; HEAD is `newSHA`.
    case reverted(newSHA: String)
    /// The revert conflicted and git's revert is PARKED
    /// (`REVERT_HEAD`) — the resolver owns continue/abort;
    /// `git revert --abort` puts everything back.
    case conflicted(conflictedPathCount: Int)
    /// `sha` doesn't resolve to a commit in this repository.
    case refusedUnknownCommit
    /// Reverting a merge commit needs a mainline parent choice —
    /// not offered in v1.
    case refusedMergeCommit
    case refusedMidstream
    case refusedStagedChanges
    case refusedDirtyWorktree
    case refusedDetachedHEAD
    /// The revert failed outright with the repo left untouched (no
    /// `REVERT_HEAD`); `reason` carries git's stderr.
    case failed(reason: String)
}

public extension HistoryOps {
    /// `git revert --no-edit <sha>` — forward-fix a commit.
    ///
    /// Guards (shared ``HistoryRewriteGuards`` set, clean tree
    /// required so the revert commit contains exactly the inverse
    /// change), then the merge-commit and existence checks. A
    /// non-zero exit with `REVERT_HEAD` present is the typed
    /// ``RevertOutcome/conflicted(conflictedPathCount:)`` — the same
    /// resolver handoff as merge/rebase/cherry-pick.
    func revert(_ sha: String) async throws -> RevertOutcome {
        let guards = HistoryRewriteGuards(runner: runner)
        switch try await guards.firstRefusal(
            requireExistingHEAD: true,
            refuseDirtyWorktree: true
        ) {
        case .detachedHEAD: return .refusedDetachedHEAD
        case .midstream: return .refusedMidstream
        case .noCommits: return .refusedUnknownCommit
        case .stagedChanges: return .refusedStagedChanges
        case .dirtyWorktree: return .refusedDirtyWorktree
        case nil: break
        }

        let resolved = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "\(sha)^{commit}"],
            throwOnNonZero: false
        )
        guard resolved.exitCode == 0 else { return .refusedUnknownCommit }

        // A second parent means a merge commit — reverting one needs
        // `-m <parent>` and a UI for choosing it (not offered yet).
        let secondParent = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "\(sha)^2"],
            throwOnNonZero: false
        )
        guard secondParent.exitCode != 0 else { return .refusedMergeCommit }

        let revert = try await runner.run(
            ["revert", "--no-edit", sha],
            throwOnNonZero: false
        )
        if revert.exitCode == 0 {
            let head = try await runner.run(["rev-parse", "HEAD"])
            return .reverted(
                newSHA: head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let worktree = runner.defaultWorkingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
        if MidstreamOperation.detectFromMarkers(gitDirURL: gitDir) == .revert {
            let unmerged = try await runner.run(["ls-files", "-u", "-z"])
            let paths = try Set(UnmergedListing.parse(unmerged.stdout).map(\.path))
            return .conflicted(conflictedPathCount: paths.count)
        }
        return .failed(
            reason: revert.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
