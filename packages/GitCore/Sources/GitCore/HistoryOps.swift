// HistoryOps.swift
//
// ADR 0082 — the two beginner-safe history edits (master plan §10:
// "Reword Last Commit", "Squash Commits"), engine half. The safety
// contract that makes them beginner-safe:
//
//   UNPUSHED ONLY. A commit reachable from ANY remote-tracking ref
//   is shared history; rewriting it forces a force-push downstream.
//   Sprig never offers that road — both verbs refuse with a typed
//   outcome instead (`git branch -r --contains` is the oracle; for
//   squash, checking the OLDEST affected commit covers the rest,
//   because a remote containing a child contains its ancestors).
//
//   NO SILENT CONTENT CHANGES. `git commit --amend` folds whatever
//   is staged into the rewritten commit — the classic trap. Both
//   verbs refuse when the index differs from HEAD, so a reword is
//   message-only and a squash is exactly the N commits' content.
//
// Callers pair these with an ADR 0033 medium-tier snapshot FIRST
// (the HistoryEditViewModel does); restoring that snapshot is the
// standard Recover `reset --hard` path back to the pre-edit tip.

import Foundation

/// Result of ``HistoryOps/rewordLastCommit(message:)``.
public enum RewordOutcome: Sendable, Equatable {
    /// HEAD's message was replaced; the tree is untouched.
    case reworded(newSHA: String)
    /// HEAD is reachable from a remote-tracking ref — shared
    /// history is never rewritten.
    case refusedShared
    /// A merge/rebase/cherry-pick is parked; finish or abort first.
    case refusedMidstream
    /// The index differs from HEAD — an amend would silently fold
    /// the staged changes in.
    case refusedStagedChanges
    /// Unborn HEAD — nothing to reword.
    case refusedNoCommits
    /// Not on a branch.
    case refusedDetachedHEAD
}

/// Result of ``HistoryOps/squashLast(_:message:)``.
public enum SquashOutcome: Sendable, Equatable {
    /// The last `replaced` commits became one; the tree is
    /// byte-identical to the old tip's.
    case squashed(newSHA: String, replaced: Int)
    /// At least one affected commit is on a remote — shared history
    /// is never rewritten.
    case refusedShared
    case refusedMidstream
    case refusedStagedChanges
    case refusedDetachedHEAD
    /// Combining fewer than 2 commits is a no-op, not a squash.
    case refusedNeedAtLeastTwo
    /// The range would swallow the root commit (HEAD~count doesn't
    /// exist) — root rewrites need different mechanics and aren't
    /// offered.
    case refusedNotEnoughHistory
}

/// History-editing operations for one repository.
public struct HistoryOps: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    /// Replace HEAD's commit message — and nothing else.
    ///
    /// Fail-closed guards, in order: on a branch, no midstream op,
    /// HEAD exists, index clean against HEAD, HEAD not on any
    /// remote. Then `git commit --amend -m <message>` (hooks run,
    /// per the defer-to-git principle; author identity and the tree
    /// are preserved by git's own amend semantics).
    public func rewordLastCommit(message: String) async throws -> RewordOutcome {
        if let refusal = try await sharedGuards() {
            return refusal.asReword
        }
        _ = try await runner.run(["commit", "--amend", "-m", message])
        return try await .reworded(newSHA: headSHA())
    }

    /// Combine the last `count` commits into one with `message`.
    ///
    /// Mechanics: `git reset --soft HEAD~count` (HEAD moves, index
    /// and worktree stay) followed by `git commit -m <message>` —
    /// the new commit's tree is byte-identical to the old tip's
    /// (test-pinned). The shared-history check runs against the
    /// OLDEST affected commit (`HEAD~(count-1)`).
    public func squashLast(_ count: Int, message: String) async throws -> SquashOutcome {
        guard count >= 2 else { return .refusedNeedAtLeastTwo }
        if let refusal = try await sharedGuards() {
            return refusal.asSquash
        }
        // The new parent must exist — a range that swallows the root
        // commit is refused, not mangled.
        guard try await resolves("HEAD~\(count)") else {
            return .refusedNotEnoughHistory
        }
        guard try await isUnshared("HEAD~\(count - 1)") else {
            return .refusedShared
        }
        _ = try await runner.run(["reset", "--soft", "HEAD~\(count)"])
        _ = try await runner.run(["commit", "-m", message])
        return try await .squashed(newSHA: headSHA(), replaced: count)
    }

    // MARK: - Shared guards

    /// The refusals common to both verbs, in the order a user can
    /// act on them.
    private enum CommonRefusal {
        case detachedHEAD
        case midstream
        case noCommits
        case stagedChanges
        case shared

        var asReword: RewordOutcome {
            switch self {
            case .detachedHEAD: .refusedDetachedHEAD
            case .midstream: .refusedMidstream
            case .noCommits: .refusedNoCommits
            case .stagedChanges: .refusedStagedChanges
            case .shared: .refusedShared
            }
        }

        var asSquash: SquashOutcome {
            switch self {
            case .detachedHEAD: .refusedDetachedHEAD
            case .midstream: .refusedMidstream
            // Squash's count guard already requires HEAD~count;
            // unborn HEAD surfaces there. Mapped defensively.
            case .noCommits: .refusedNotEnoughHistory
            case .stagedChanges: .refusedStagedChanges
            case .shared: .refusedShared
            }
        }
    }

    private func sharedGuards() async throws -> CommonRefusal? {
        let common = try await HistoryRewriteGuards(runner: runner).firstRefusal(
            requireExistingHEAD: true,
            refuseDirtyWorktree: false
        )
        switch common {
        case .detachedHEAD: return .detachedHEAD
        case .midstream: return .midstream
        case .noCommits: return .noCommits
        case .stagedChanges: return .stagedChanges
        case .dirtyWorktree: return nil // not requested for message-only edits
        case nil: break
        }
        guard try await isUnshared("HEAD") else { return .shared }
        return nil
    }

    /// Is `rev` absent from every remote-tracking ref?
    private func isUnshared(_ rev: String) async throws -> Bool {
        let result = try await runner.run(["branch", "-r", "--contains", rev])
        return result.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func resolves(_ rev: String) async throws -> Bool {
        let result = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "\(rev)^{commit}"],
            throwOnNonZero: false
        )
        return result.exitCode == 0
    }

    private func headSHA() async throws -> String {
        try await runner.run(["rev-parse", "HEAD"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
