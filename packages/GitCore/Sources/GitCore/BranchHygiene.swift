// BranchHygiene.swift
//
// ADR 0073 engine surface: detect local branches whose remote
// counterpart is gone (the typical "merged on the server, branch
// deleted by the forge" aftermath) and delete them safely.
//
// The detection input is the same one-pass `branchSyncStates()` read
// ADR 0068 uses — a branch qualifies when its configured upstream's
// tracking ref no longer exists (post `fetch --prune`). Safety
// classification then asks git, never guesses:
//
//   * `git merge-base --is-ancestor <branch> <default-remote-ref>` —
//     tip reachable from the server's default branch ⇒ nothing is
//     lost by deleting (the forge merged it).
//   * otherwise `git rev-list --count <branch> ^<default-remote-ref>`
//     counts the commits that exist nowhere else — the number the
//     confirmation UI shows, and the reason ADR 0033 classifies this
//     delete as medium-tier (snapshot first).
//
// Deletion is two distinct verbs on purpose: ``deleteBranch(named:)``
// is plain `git branch -d` (git's own merged-check, calibrated
// against HEAD — note that baseline FALSE-REFUSES the canonical
// "server merged it, local default branch hasn't pulled yet" case,
// which is why the hygiene view model deletes on the engine's
// ancestor-of-remote-default proof via ``forceDeleteBranch(named:)``
// instead), and ``forceDeleteBranch(named:)`` is `git branch -D` for
// callers whose safety proof is the classification above — or, for
// unmerged tips, an ADR 0033 snapshot taken first (the view-model
// layer owns that pairing; GitCore doesn't depend on SafetyKit).

import Foundation

/// Stale-branch detection + deletion for one repository.
public struct BranchHygiene: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    // MARK: - Detection

    /// Local branches whose upstream is configured but gone
    /// (deleted on the remote + pruned), classified for deletion
    /// safety against the remote's default branch.
    ///
    /// Returns an empty array when no remote default branch can be
    /// resolved (no remotes / empty remote) — without a baseline,
    /// "safe" is unknowable and the affordance stays quiet.
    public func staleBranches() async throws -> [StaleBranch] {
        let states = try await SyncOps(runner: runner).branchSyncStates()
        let gone = states.filter(\.upstreamGone)
        guard !gone.isEmpty else { return [] }
        guard let baseline = try await defaultRemoteRef() else { return [] }

        var result: [StaleBranch] = []
        result.reserveCapacity(gone.count)
        for state in gone {
            let merged = try await isAncestor(state.name, of: baseline)
            let unpushed = merged ? 0 : try await uniqueCommitCount(of: state.name, against: baseline)
            result.append(StaleBranch(
                name: state.name,
                sha: state.sha,
                formerUpstream: state.upstreamShort,
                isCurrent: state.isCurrent,
                safeToDelete: merged && !state.isCurrent,
                unpushedCommitCount: unpushed
            ))
        }
        return result
    }

    /// The remote's default branch ref (`origin/main` etc.), resolved
    /// from `refs/remotes/origin/HEAD` (set by `git clone`); falls
    /// back to `origin/main` then `origin/master` when the symref is
    /// absent (e.g. the remote was added by hand). Nil when nothing
    /// resolves.
    func defaultRemoteRef() async throws -> String? {
        let symref = try await runner.run(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            throwOnNonZero: false
        )
        if symref.exitCode == 0 {
            let name = symref.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        for candidate in ["origin/main", "origin/master"] {
            let probe = try await runner.run(
                ["rev-parse", "--quiet", "--verify", "refs/remotes/\(candidate)"],
                throwOnNonZero: false
            )
            if probe.exitCode == 0 { return candidate }
        }
        return nil
    }

    private func isAncestor(_ branch: String, of baseline: String) async throws -> Bool {
        let result = try await runner.run(
            ["merge-base", "--is-ancestor", branch, baseline],
            throwOnNonZero: false
        )
        return result.exitCode == 0
    }

    private func uniqueCommitCount(of branch: String, against baseline: String) async throws -> Int {
        let result = try await runner.run(["rev-list", "--count", branch, "^\(baseline)"])
        return Int(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Deletion

    /// `git branch -d <name>` — git's own merged-check applies, so
    /// even a mis-classified branch can't lose commits through this
    /// verb. Refusals (unmerged tip, checked-out branch) come back
    /// typed, not thrown.
    public func deleteBranch(named name: String) async throws -> BranchDeleteOutcome {
        try await runDelete(["branch", "-d", name], name: name)
    }

    /// `git branch -D <name>` — for callers that have already taken
    /// the ADR 0033 medium-tier safety snapshot of the branch tip.
    /// Never call this without one (the TaskWindowKit view model
    /// pairs the two; see `BranchHygieneViewModel`).
    public func forceDeleteBranch(named name: String) async throws -> BranchDeleteOutcome {
        try await runDelete(["branch", "-D", name], name: name)
    }

    private func runDelete(_ args: [String], name: String) async throws -> BranchDeleteOutcome {
        let result = try await runner.run(args, throwOnNonZero: false)
        if result.exitCode == 0 {
            return .deleted(branch: name)
        }
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        // git's stable refusal phrasings (unlocalized in Sprig's
        // scrubbed environment — same contract as ADR 0069/0071
        // classification).
        if stderr.contains("not fully merged") {
            return .refusedNotMerged(branch: name)
        }
        if stderr.contains("used by worktree") || stderr.contains("checked out") {
            return .refusedCheckedOut(branch: name)
        }
        return .failed(reason: stderr)
    }
}

/// One local branch whose upstream is gone, classified for cleanup.
public struct StaleBranch: Sendable, Equatable {
    /// Short branch name.
    public let name: String
    /// Tip SHA at detection time.
    public let sha: String
    /// The upstream that no longer exists (e.g. `origin/feature/x`).
    public let formerUpstream: String?
    /// The branch is checked out here — never offered for deletion.
    public let isCurrent: Bool
    /// Tip is reachable from the remote default branch AND the branch
    /// isn't checked out: deleting loses nothing.
    public let safeToDelete: Bool
    /// Commits on this branch that the remote default branch doesn't
    /// have (0 when ``safeToDelete``). The number the confirmation
    /// shows; >0 ⇒ ADR 0033 medium tier (snapshot before delete).
    public let unpushedCommitCount: Int

    public init(
        name: String,
        sha: String,
        formerUpstream: String?,
        isCurrent: Bool,
        safeToDelete: Bool,
        unpushedCommitCount: Int
    ) {
        self.name = name
        self.sha = sha
        self.formerUpstream = formerUpstream
        self.isCurrent = isCurrent
        self.safeToDelete = safeToDelete
        self.unpushedCommitCount = unpushedCommitCount
    }
}

/// Result of a ``BranchHygiene`` delete call.
public enum BranchDeleteOutcome: Sendable, Equatable {
    case deleted(branch: String)
    /// `git branch -d` refused an unmerged tip (its own safety net).
    case refusedNotMerged(branch: String)
    /// The branch is checked out (here or in a linked worktree).
    case refusedCheckedOut(branch: String)
    case failed(reason: String)
}
