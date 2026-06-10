// StashOps.swift
//
// ADR 0069 engine surface: the stash push/pop primitives behind the
// "Set aside changes" affordance (auto-stash around branch switch,
// and later around pull — git-beginner-affordances.md item 1.3).
//
// Outcome detection is deliberately plumbing-based, not
// message-based: `git stash push` exits 0 both when it stashed and
// when there was nothing to stash, and its human messages aren't a
// stable contract. We compare `refs/stash` before/after instead.
// Same for pop: a conflicted pop exits non-zero AND keeps the stash
// entry — `refs/stash` still resolving afterwards is the reliable
// "kept" signal.

import Foundation

/// Stash operations for one repository, shelling out via the wrapped
/// ``Runner`` (which carries the repo's working directory).
public struct StashOps: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    /// `git stash push [-u] -m <message>`.
    ///
    /// - Parameters:
    ///   - message: stash subject — shows up in `git stash list` and
    ///     the future Stash task window, so callers should say who
    ///     created it and why (e.g. "Sprig: set aside before
    ///     switching to feature/x").
    ///   - includeUntracked: also stash untracked files (`-u`).
    ///     Defaults true: the "set aside changes" affordance promises
    ///     a clean tree afterwards, and a beginner's in-progress work
    ///     is often still untracked.
    /// - Returns: ``StashPushOutcome/created(sha:)`` with the new
    ///   stash commit's SHA, or ``StashPushOutcome/nothingToStash``
    ///   when the tree was already clean (git exits 0 there too).
    public func push(
        message: String,
        includeUntracked: Bool = true
    ) async throws -> StashPushOutcome {
        let before = try await stashTipSHA()
        var args = ["stash", "push"]
        if includeUntracked {
            args.append("--include-untracked")
        }
        args.append(contentsOf: ["-m", message])
        _ = try await runner.run(args)
        let after = try await stashTipSHA()
        if let after, after != before {
            return .created(sha: after)
        }
        return .nothingToStash
    }

    /// `git stash pop` — apply the most recent stash entry and drop
    /// it on success.
    ///
    /// - Returns: ``StashPopOutcome/applied`` when the entry applied
    ///   cleanly (and was dropped), or
    ///   ``StashPopOutcome/keptDueToConflict(detail:)`` when applying
    ///   conflicted — git leaves conflict markers in the worktree AND
    ///   keeps the stash entry, so nothing is lost; the user resolves
    ///   (or `git checkout -- .` + `git stash pop` again later).
    /// - Throws: ``GitError`` when there is no stash entry to pop, or
    ///   on unexpected failures where the stash entry did NOT survive
    ///   (never observed; defensive).
    public func pop() async throws -> StashPopOutcome {
        guard try await stashTipSHA() != nil else {
            throw GitError.nonZeroExit(
                command: ["stash", "pop"],
                exitCode: 1,
                stderr: "No stash entries found.",
                stdout: ""
            )
        }
        let result = try await runner.run(["stash", "pop"], throwOnNonZero: false)
        if result.exitCode == 0 {
            return .applied
        }
        // Non-zero: conflicted (or blocked) pop. git's contract is to
        // keep the entry in that case — verify before reporting the
        // recoverable outcome.
        guard try await stashTipSHA() != nil else {
            throw GitError.nonZeroExit(
                command: ["stash", "pop"],
                exitCode: result.exitCode,
                stderr: result.stderrString,
                stdout: result.stdoutString
            )
        }
        let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return .keptDueToConflict(
            detail: detail.isEmpty
                ? result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                : detail
        )
    }

    /// SHA of `refs/stash`, or nil when no stash entries exist.
    private func stashTipSHA() async throws -> String? {
        let result = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "refs/stash"],
            throwOnNonZero: false
        )
        guard result.exitCode == 0 else { return nil }
        let sha = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }
}

/// Result of ``StashOps/push(message:includeUntracked:)``.
public enum StashPushOutcome: Sendable, Equatable {
    /// A stash entry was created; `sha` is its commit (also reachable
    /// as `stash@{0}` until another entry lands on top).
    case created(sha: String)
    /// Worktree + index were already clean; nothing happened.
    case nothingToStash
}

/// Result of ``StashOps/pop()``.
public enum StashPopOutcome: Sendable, Equatable {
    /// Applied cleanly; the entry was dropped.
    case applied
    /// Applying conflicted (or was blocked); conflict markers may be
    /// in the worktree and **the stash entry is kept** — `detail`
    /// carries git's explanation for surfacing to the user.
    case keptDueToConflict(detail: String)
}
