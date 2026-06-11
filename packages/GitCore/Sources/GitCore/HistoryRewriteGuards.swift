// HistoryRewriteGuards.swift
//
// The fail-closed precondition set shared by every history-rewriting
// surface (ADR 0082 reword/squash, ADR 0083 rebase plans — and the
// ADR 0051 restack verb next). Extracted 2026-06-11 so a third
// consumer can't fork the sequence: the checks run in the order a
// user can act on them, and each consumer maps the refusal into its
// own typed outcome.
//
// The shared-history check (`branch -r --contains`) deliberately
// stays OUT of this helper — each verb checks a different rev (HEAD
// for reword, the oldest affected commit for squash, the whole
// unpushed range for plans).

import Foundation

/// Preconditions common to history rewrites, checked in
/// user-actionable order.
struct HistoryRewriteGuards {
    /// The first failed precondition, if any.
    enum Refusal {
        case detachedHEAD
        case midstream
        case noCommits
        case stagedChanges
        case dirtyWorktree
    }

    let runner: Runner

    /// - Parameters:
    ///   - requireExistingHEAD: refuse with ``Refusal/noCommits`` on
    ///     an unborn HEAD (reword/squash need a commit to edit; plan
    ///     surfaces detect emptiness via their own range query).
    ///   - refuseDirtyWorktree: also require clean *tracked* files —
    ///     the guard a worktree-touching replay (rebase) needs and a
    ///     message-only amend doesn't.
    func firstRefusal(
        requireExistingHEAD: Bool,
        refuseDirtyWorktree: Bool
    ) async throws -> Refusal? {
        let onBranch = try await runner.run(
            ["symbolic-ref", "--quiet", "HEAD"],
            throwOnNonZero: false
        )
        guard onBranch.exitCode == 0 else { return .detachedHEAD }

        let worktree = runner.defaultWorkingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
        guard MidstreamOperation.detectFromMarkers(gitDirURL: gitDir) == .none else {
            return .midstream
        }

        if requireExistingHEAD {
            let head = try await runner.run(
                ["rev-parse", "--quiet", "--verify", "HEAD^{commit}"],
                throwOnNonZero: false
            )
            guard head.exitCode == 0 else { return .noCommits }
        }

        // `diff --cached --quiet` exits 1 when the index differs from
        // HEAD — the changes an amend/replay would silently absorb.
        let staged = try await runner.run(
            ["diff", "--cached", "--quiet"],
            throwOnNonZero: false
        )
        guard staged.exitCode == 0 else { return .stagedChanges }

        if refuseDirtyWorktree {
            let dirty = try await runner.run(
                ["diff", "--quiet"],
                throwOnNonZero: false
            )
            guard dirty.exitCode == 0 else { return .dirtyWorktree }
        }
        return nil
    }
}
