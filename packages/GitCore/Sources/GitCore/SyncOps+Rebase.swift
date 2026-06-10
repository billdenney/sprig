// SyncOps+Rebase.swift
//
// ADR 0071 amendment: the explicit "replay my commits on top of the
// server's, then push" follow-up for a diverged branch. This file is
// the rebase half only — the engine primitive a UI action or CLI
// flag invokes AFTER the user chose it from the diverged report.
// Never run automatically inside Sync (the amendment's first
// property), and never followed by anything but a PLAIN push (the
// push half is the existing `pushCurrentBranch`; a re-rejection
// re-reports).
//
// Fail-closed rules, mirroring the fast-forward leg:
//   - tracked modifications → typed skip (the UI offers ADR 0069's
//     set-aside; no implicit autostash around history rewriting);
//   - only a genuinely diverged branch proceeds — behind-only is the
//     FF leg's job, ahead-only is the push leg's;
//   - a conflicted rebase is left IN PLACE (typed `.conflicted`):
//     the M4 resolver owns continuation, `rebase --abort` is the
//     one-tap undo. Aborting on the caller's behalf would discard
//     the user's explicit intent to integrate.
//
// Callers that owe ADR 0033 a snapshot (this is a medium-tier op —
// `DestructiveOpTier.tier(for: SnapshotRefName.opRebase)`) take it
// BEFORE calling; SafetyKit sits above GitCore, so the snapshot
// cannot be taken here.

import Foundation

/// Typed result of ``SyncOps/rebaseOntoUpstream()``.
public enum RebaseOutcome: Sendable, Equatable {
    /// Rebase completed: `replayed` local commits now sit on top of
    /// `onto` (the upstream's remote-tracking ref at rebase time).
    case rebased(branch: String, onto: String, replayed: Int)
    /// The branch isn't diverged — nothing to replay. Behind-only
    /// belongs to the fast-forward leg, ahead-only to the push leg.
    case notDiverged(branch: String)
    /// The rebase stopped on conflicts and was deliberately left in
    /// progress: `conflictedPathCount` paths need a decision in the
    /// resolver, or one `git rebase --abort` undoes everything.
    case conflicted(branch: String, conflictedPathCount: Int)
    /// No upstream configured; there is nothing to rebase onto.
    case noUpstream(branch: String)
    /// Detached HEAD — no current branch to rebase.
    case detachedHEAD
    /// Tracked modifications present; rewriting is refused. The UI
    /// offers the ADR 0069 set-aside flow, then retries.
    case dirtyWorktree(branch: String)
    /// Rebase failed for a non-conflict reason (hook refusal, GC
    /// lock, …) and the repo is NOT mid-rebase.
    case failed(reason: String)
}

public extension SyncOps {
    /// `git rebase <upstream>` for the currently checked-out,
    /// diverged branch — the ADR 0071-amendment follow-up action.
    ///
    /// Reads the same one-pass branch state the other legs use, so
    /// "diverged" means diverged against the **already-fetched**
    /// remote-tracking ref; callers fetch first (Sync just did).
    func rebaseOntoUpstream() async throws -> RebaseOutcome {
        let states = try await branchSyncStates()
        guard let current = states.first(where: \.isCurrent) else {
            return .detachedHEAD
        }
        guard let upstream = current.upstreamShort, !current.upstreamGone else {
            return .noUpstream(branch: current.name)
        }
        guard current.ahead > 0, current.behind > 0 else {
            return .notDiverged(branch: current.name)
        }
        if try await hasTrackedModifications() {
            return .dirtyWorktree(branch: current.name)
        }

        let rebase = try await runner.run(["rebase", upstream], throwOnNonZero: false)
        if rebase.exitCode == 0 {
            return .rebased(branch: current.name, onto: upstream, replayed: current.ahead)
        }

        // Non-zero: conflict (repo left mid-rebase for the resolver)
        // vs. outright failure (repo untouched). The marker files are
        // the discriminator, same signal the ADR 0056 guard reads.
        let worktree = runner.defaultWorkingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
        if MidstreamOperation.detectFromMarkers(gitDirURL: gitDir) == .rebase {
            let unmerged = try await runner.run(["ls-files", "-u", "-z"])
            let paths = try Set(UnmergedListing.parse(unmerged.stdout).map(\.path))
            return .conflicted(branch: current.name, conflictedPathCount: paths.count)
        }
        return .failed(
            reason: rebase.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
