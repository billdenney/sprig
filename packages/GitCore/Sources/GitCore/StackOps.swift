// StackOps.swift
//
// ADR 0085 (ADR 0051 substrate) — the stacked-branch RESTACK engine.
// When a parent branch in a stack (main ← feature-a ← feature-b …)
// moves, replay each child's OWN commits onto its parent's new tip.
// The primitive is `git rebase --onto <parent-tip> <fork-point>
// <child>` — defer to git's sequencer (ADR 0023), exactly as
// RebasePlanOps (ADR 0083) does, including the conflict-park handoff.
//
// Fork-point tracking (the load-bearing decision, empirically pinned
// — see ADR 0085's rejected options): TWO local git-config keys per
// stacked child —
//   * `branch.<child>.sprigParent` = the parent BRANCH NAME (ADR 0051).
//   * `branch.<child>.sprigBase`   = the 40-hex FORK COMMIT, frozen
//     at link time as `git merge-base <parent> <child>`.
// The `<upstream>` arg to rebase is the RECORDED sprigBase, never a
// freshly recomputed merge-base — a live merge-base slides down to
// trunk after a parent rewrite and replays the parent's orphaned
// commits (a spurious add/add conflict, shown in the spike). The
// recorded fork commit is untouched by a parent reword/squash (which
// rewrites the parent's commits ABOVE the fork), so `sprigBase..child`
// always isolates exactly the child's own commits. After a successful
// restack the fork is re-frozen to the new parent tip.
//
// Safety (ADR 0051 amendment / master-plan §2.5): restack NEVER
// rewrites the parent or trunk — they are read-only inputs; only the
// author-owned child branch advances. The child is expected to be
// force-pushed afterward (the stacked-PR contract), but restack emits
// NO push — publishing the rewritten child is the separate high-tier
// force-push verb. The ADR 0033 medium-tier snapshot is taken in the
// TaskWindowKit layer (StackOps stays snapshot-free, like RebasePlanOps).
//
// v1 ships the SINGLE-CHILD primitive; the multi-branch
// `restackDescendants` walk is deferred (it needs the SnapshotWriter
// same-second-collision uniquifier first). `.refusedStackCycle` is
// reserved in the outcome enum so adding the walk is not a breaking
// change.

import Foundation

/// Result of ``StackOps/restack(branch:)``.
public enum StackRestackOutcome: Sendable, Equatable {
    /// The child replayed cleanly onto its parent's new tip; HEAD is
    /// `newTip` (rebase checks the child out). The fork-point was
    /// re-frozen to the new parent tip.
    case completed(newTip: String)
    /// The replay conflicted and git's rebase is PARKED — the M4
    /// resolver owns `--continue`/`--abort`; `git rebase --abort`
    /// returns the child to its exact pre-restack tip. `branch` names
    /// which child parked (a stack op must say which).
    case conflicted(branch: String, conflictedPathCount: Int)
    /// The child has no commits of its own beyond the fork point —
    /// nothing to replay.
    case refusedNothingToRestack
    /// No `branch.<child>.sprigParent` recorded — the user must say
    /// which branch this one is stacked on first.
    case refusedNoParentRecorded
    /// The recorded fork point is no longer an ancestor of the child
    /// (child reset below the fork, the base gc'd, or a half-recorded
    /// link) — refuse rather than guess a live merge-base.
    case refusedForkPointDiverged
    /// Reserved for the deferred `restackDescendants` walk (a cycle in
    /// the recorded parent graph). The v1 single-child path never
    /// emits it.
    case refusedStackCycle
    case refusedMidstream
    case refusedStagedChanges
    case refusedDirtyWorktree
    case refusedDetachedHEAD
    /// The rebase failed outright with the repo left untouched (no
    /// rebase markers): a missing parent ref, a hook refusal, a lock.
    case failed(reason: String)
}

/// Stacked-branch operations for one repository.
public struct StackOps: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    // MARK: - Stack links (git config CRUD)

    /// The parent branch name recorded for `branch`, or nil when no
    /// link is recorded.
    public func recordedParent(of branch: String) async throws -> String? {
        try await readConfig("branch.\(branch).sprigParent")
    }

    /// The frozen fork-point SHA recorded for `branch`, or nil when
    /// unset.
    public func recordedForkPoint(of branch: String) async throws -> String? {
        try await readConfig("branch.\(branch).sprigBase")
    }

    /// Record that `child` is stacked on `parent`: writes the parent
    /// name and freezes the fork point at `git merge-base parent child`.
    /// Both writes are local scope (never `--global`).
    ///
    /// - Throws: ``GitError`` if either branch doesn't exist or the
    ///   two share no history (no merge base) — recording a link
    ///   between unrelated branches is a user error.
    public func recordStackLink(child: String, parent: String) async throws {
        _ = try await runner.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(child)"])
        _ = try await runner.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(parent)"])
        let base = try await runner.run(["merge-base", parent, child])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["config", "branch.\(child).sprigParent", parent])
        _ = try await runner.run(["config", "branch.\(child).sprigBase", base])
        // Clean slate: a fresh link voids any pending fork from a prior
        // parked restack on this branch.
        try await clearPendingBase(branch: child)
    }

    /// Forget `branch`'s stack link (idempotent — tolerates the keys
    /// already being absent).
    public func unlinkStack(branch: String) async throws {
        _ = try await runner.run(
            ["config", "--unset", "branch.\(branch).sprigParent"],
            throwOnNonZero: false
        )
        _ = try await runner.run(
            ["config", "--unset", "branch.\(branch).sprigBase"],
            throwOnNonZero: false
        )
        try await clearPendingBase(branch: branch)
    }

    /// The branches whose recorded `sprigParent` is `branch` — its
    /// direct children in the stack. One `for-each-ref`-free pass via
    /// `config --get-regexp` (read-only; the visualization surfaces
    /// and the deferred walk consume it).
    public func stackChildren(of branch: String) async throws -> [String] {
        // git canonicalizes the variable name to lowercase in
        // --get-regexp output (`sprigParent` → `sprigparent`); the
        // subsection (branch name) keeps its case.
        let listing = try await runner.run(
            ["config", "--get-regexp", #"^branch\..*\.sprigparent$"#],
            throwOnNonZero: false
        )
        guard listing.exitCode == 0 else { return [] }
        return listing.stdoutString.split(separator: "\n").compactMap { line in
            // "branch.<child>.sprigparent <parent>" — child may contain
            // dots, so strip the known prefix/suffix off the key.
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, String(parts[1]) == branch else { return nil }
            let key = String(parts[0])
            guard key.hasPrefix("branch."), key.hasSuffix(".sprigparent") else { return nil }
            let child = key.dropFirst("branch.".count).dropLast(".sprigparent".count)
            return child.isEmpty ? nil : String(child)
        }
    }

    // MARK: - Restack (the v1 primitive)

    /// Replay `branch`'s own commits onto its recorded parent's
    /// current tip via `git rebase --onto <parent-tip> <fork-point>
    /// <branch>`.
    ///
    /// Guards (shared ``HistoryRewriteGuards`` set: on a branch, no
    /// parked midstream op, clean index + tracked worktree), then the
    /// recorded-link + fork-point-ancestry checks, then the empty-range
    /// check, then the rebase. On success the fork point is re-frozen
    /// to the new parent tip. A conflict parks git's rebase for the
    /// resolver. Never rewrites the parent/trunk; never pushes.
    public func restack(branch: String) async throws -> StackRestackOutcome {
        if let refusal = try await guardRefusal() { return refusal }
        switch try await resolvePlan(branch: branch) {
        case let .refuse(outcome):
            return outcome
        case let .proceed(parentTip, forkPoint):
            return try await runRebase(branch: branch, onto: parentTip, from: forkPoint)
        }
    }

    // MARK: - Restack phases

    /// The shared-guard set mapped into restack's typed refusals (no
    /// shared-history `branch -r --contains` check — stacked children
    /// are author-owned replay targets, ADR 0085).
    private func guardRefusal() async throws -> StackRestackOutcome? {
        switch try await HistoryRewriteGuards(runner: runner).firstRefusal(
            requireExistingHEAD: false,
            refuseDirtyWorktree: true
        ) {
        case .detachedHEAD: .refusedDetachedHEAD
        case .midstream: .refusedMidstream
        case .stagedChanges: .refusedStagedChanges
        case .dirtyWorktree: .refusedDirtyWorktree
        case .noCommits: .refusedNothingToRestack
        case nil: nil
        }
    }

    private enum PlanResolution {
        case refuse(StackRestackOutcome)
        case proceed(parentTip: String, forkPoint: String)
    }

    /// Read + validate the recorded link and the replay range without
    /// touching the repo.
    private func resolvePlan(branch: String) async throws -> PlanResolution {
        guard let parent = try await recordedParent(of: branch) else {
            return .refuse(.refusedNoParentRecorded)
        }
        // Self-heal a fork left pending by a previously parked-then-
        // continued restack before reading it.
        try await reconcilePendingBase(branch: branch)
        guard let forkPoint = try await recordedForkPoint(of: branch),
              try await isAncestor(forkPoint, of: branch)
        else {
            return .refuse(.refusedForkPointDiverged)
        }
        // A recorded link to a deleted parent is repo-untouched failure.
        let parentTipResult = try await runner.run(
            ["rev-parse", "--verify", "--quiet", "refs/heads/\(parent)"],
            throwOnNonZero: false
        )
        guard parentTipResult.exitCode == 0 else {
            return .refuse(.failed(reason: "recorded parent branch '\(parent)' not found"))
        }
        // Nothing of the child's own to replay → no pointless snapshot.
        let ownCount = try await runner.run(
            ["rev-list", "--count", "\(forkPoint)..\(branch)"]
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ownCount != "0" else { return .refuse(.refusedNothingToRestack) }
        return .proceed(
            parentTip: parentTipResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
            forkPoint: forkPoint
        )
    }

    private func runRebase(
        branch: String,
        onto parentTip: String,
        from forkPoint: String
    ) async throws -> StackRestackOutcome {
        // The new fork (after this restack completes — clean inline OR
        // conflict-then-resolver-continue) WILL be parentTip. Record it
        // transiently FIRST: a conflicted restack is continued by the
        // stack-unaware resolver, which can't re-freeze sprigBase, so
        // the next restack self-heals from this pending value (or
        // discards it if the parked rebase was aborted).
        _ = try await runner.run(["config", "branch.\(branch).sprigPendingBase", parentTip])
        let rebase = try await runner.run(
            ["rebase", "--onto", parentTip, forkPoint, branch],
            throwOnNonZero: false
        )
        if rebase.exitCode == 0 {
            try await promotePendingBase(branch: branch, to: parentTip)
            return try await .completed(newTip: headSHA())
        }
        // Non-zero: conflict (rebase parked for the resolver) vs outright
        // failure (repo untouched) — the marker files are the
        // discriminator, identical to RebasePlanOps / SyncOps' leg.
        let worktree = runner.defaultWorkingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
        if MidstreamOperation.detectFromMarkers(gitDirURL: gitDir) == .rebase {
            // Leave sprigPendingBase set — the next restack promotes it
            // once the child sits on it (after the resolver continues).
            let unmerged = try await runner.run(["ls-files", "-u", "-z"])
            let paths = try Set(UnmergedListing.parse(unmerged.stdout).map(\.path))
            return .conflicted(branch: branch, conflictedPathCount: paths.count)
        }
        // Repo untouched: the intended fork never took, so discard it.
        try await clearPendingBase(branch: branch)
        return .failed(
            reason: rebase.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Pending-fork self-heal

    /// Promote or discard a fork left pending by a parked-then-resolved
    /// restack. If the child now sits on the pending base (the resolver
    /// continued the rebase onto it), freeze it; if not (the rebase was
    /// aborted), drop it and keep the recorded fork.
    private func reconcilePendingBase(branch: String) async throws {
        guard let pending = try await readConfig("branch.\(branch).sprigPendingBase") else { return }
        if try await isAncestor(pending, of: branch) {
            try await promotePendingBase(branch: branch, to: pending)
        } else {
            try await clearPendingBase(branch: branch)
        }
    }

    private func promotePendingBase(branch: String, to base: String) async throws {
        _ = try await runner.run(["config", "branch.\(branch).sprigBase", base])
        try await clearPendingBase(branch: branch)
    }

    private func clearPendingBase(branch: String) async throws {
        _ = try await runner.run(
            ["config", "--unset", "branch.\(branch).sprigPendingBase"],
            throwOnNonZero: false
        )
    }

    // MARK: - Internals

    private func readConfig(_ key: String) async throws -> String? {
        let result = try await runner.run(["config", "--get", key], throwOnNonZero: false)
        guard result.exitCode == 0 else { return nil }
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isAncestor(_ ancestor: String, of branch: String) async throws -> Bool {
        let result = try await runner.run(
            ["merge-base", "--is-ancestor", ancestor, branch],
            throwOnNonZero: false
        )
        return result.exitCode == 0
    }

    private func headSHA() async throws -> String {
        try await runner.run(["rev-parse", "HEAD"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
