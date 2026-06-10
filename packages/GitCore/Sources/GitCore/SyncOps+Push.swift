// SyncOps+Push.swift
//
// ADR 0071: the push half of the Sync verb. ``SyncOps`` (ADR 0068)
// covers fetch + fast-forward; this extension adds the one push shape
// the verb is allowed to perform: a **plain, never-forced push of the
// current branch**, publishing a new upstream when none exists.
//
// Force variants are deliberately absent — the explicit Force Push
// verb (ADR 0052: always `--force-with-lease --force-if-includes`)
// is a different, high-tier surface. A rejected push here is a typed
// *report* ("needs your attention: histories diverged"), never an
// escalation.

import Foundation

public extension SyncOps {
    /// Push the currently checked-out branch to its upstream — or
    /// publish it (`push -u <remote> <branch>`) when no upstream is
    /// configured and the repo has at least one remote.
    ///
    /// Never forces. A non-fast-forward rejection comes back as
    /// ``PushOutcome/rejectedNonFastForward(branch:)`` so callers
    /// route the user to fetch + resolve, not to `--force`.
    ///
    /// - Parameter remoteForNewUpstream: remote used for the
    ///   publish-new-upstream path when several exist. Defaults to
    ///   `"origin"`; if that name doesn't exist the first listed
    ///   remote is used.
    func pushCurrentBranch(
        remoteForNewUpstream: String = "origin"
    ) async throws -> PushOutcome {
        let states = try await branchSyncStates()
        guard let current = states.first(where: \.isCurrent) else {
            return .detachedHEAD
        }

        guard let upstream = current.upstreamShort else {
            return try await publishNewUpstream(
                branch: current.name,
                preferredRemote: remoteForNewUpstream
            )
        }

        guard current.ahead > 0 else {
            return .nothingToPush(branch: current.name)
        }

        let push = try await runner.run(["push", "--quiet"], throwOnNonZero: false)
        guard push.exitCode == 0 else {
            return Self.classifyPushFailure(
                branch: current.name,
                stderr: push.stderrString
            )
        }
        return .pushed(branch: current.name, upstream: upstream, commits: current.ahead)
    }

    /// `git push -u <remote> <branch>` for a branch with no upstream.
    private func publishNewUpstream(
        branch: String,
        preferredRemote: String
    ) async throws -> PushOutcome {
        let remotes = try await runner.run(["remote"])
        let names = remotes.stdoutString
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return .noRemotes(branch: branch)
        }
        let remote = names.contains(preferredRemote) ? preferredRemote : names[0]

        let push = try await runner.run(
            ["push", "--quiet", "-u", remote, branch],
            throwOnNonZero: false
        )
        guard push.exitCode == 0 else {
            return Self.classifyPushFailure(branch: branch, stderr: push.stderrString)
        }
        return .publishedNewUpstream(branch: branch, remote: remote)
    }

    /// Map a failed push's stderr to a typed outcome. git's
    /// rejection phrasings ("non-fast-forward", "[rejected]",
    /// "fetch first") are stable English (git is unlocalized in
    /// Sprig's scrubbed environment — same contract
    /// `BranchSwitcherViewModel.isDirtyTreeRefusal` relies on).
    static func classifyPushFailure(branch: String, stderr: String) -> PushOutcome {
        let rejectionMarkers = ["non-fast-forward", "[rejected]", "fetch first"]
        if rejectionMarkers.contains(where: stderr.contains) {
            return .rejectedNonFastForward(branch: branch)
        }
        return .failed(reason: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Result of ``SyncOps/pushCurrentBranch(remoteForNewUpstream:)``.
/// Everything except ``failed(reason:)`` is an expected, reportable
/// state — the Sync verb renders each as a one-line summary.
public enum PushOutcome: Sendable, Equatable {
    /// `commits` local commits went up to `upstream`.
    case pushed(branch: String, upstream: String, commits: Int)
    /// Upstream already has everything (`ahead == 0`).
    case nothingToPush(branch: String)
    /// No upstream existed; the branch was published to `remote` and
    /// now tracks it.
    case publishedNewUpstream(branch: String, remote: String)
    /// The remote moved on (histories diverged). The remedy is
    /// fetch + resolve — never an automatic force.
    case rejectedNonFastForward(branch: String)
    /// No remotes are configured; nowhere to push.
    case noRemotes(branch: String)
    /// HEAD is detached; there is no current branch to push.
    case detachedHEAD
    /// Push failed for another reason; `reason` carries git's stderr.
    case failed(reason: String)
}
