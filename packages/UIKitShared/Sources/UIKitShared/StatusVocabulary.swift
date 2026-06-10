// StatusVocabulary.swift
//
// ADR 0072 — the single place where Sprig's typed engine outcomes
// become user-facing copy, in two registers:
//
//   * `.plain` — the beginner register (affordances item 2.1):
//     everyday words, tight. `(git: …)` teaching parentheticals are
//     reserved for the decision points where knowing the git term
//     genuinely helps (maintainer-ratified 2026-06-11): DIVERGED,
//     DETACHED HEAD, and the never-forces push rejection. Everywhere
//     else the plain words stand alone — users graduate into the
//     vocabulary at the moments that teach, not on every line.
//   * `.git` — the terse register: sprigctl's existing output,
//     byte-for-byte (its tests pin these strings), and the shells'
//     power-user reveal level (ADR 0019).
//
// Rules of the house:
//   - VMs never format; they expose typed outcomes. Shells + the CLI
//     ask this vocabulary.
//   - No locale-dependent formatters (ByteCountFormatter et al.) —
//     output must be deterministic across platforms and test
//     environments. English-only at 1.0 per ADR 0042; this file is
//     the localization surface when that lands.
//   - Strings in the `.git` register are wire-adjacent: sprigctl
//     tests assert them. Don't reword without updating those tests
//     deliberately.
//
// Structure note: every public `describe` dispatches to one private
// function per register, each a single switch over the outcome —
// keeps SwiftLint's cyclomatic-complexity cap happy and keeps each
// register's copy readable as a unit.

import Foundation
import GitCore
import TaskWindowKit

/// Which audience a string is for. ADR 0019's reveal level picks the
/// register in the shells; sprigctl always uses `.git`.
public enum VocabularyRegister: Sendable, Equatable {
    /// Beginner-first phrasing with the git term in parentheses.
    case plain
    /// Terse git-native phrasing (sprigctl's existing output).
    case git
}

/// Stateless formatter for the engine's typed outcomes.
public enum StatusVocabulary {
    // MARK: - Branch relationship (BranchSyncState)

    /// The "where this branch stands vs its upstream" phrase, without
    /// the branch-name prefix (callers compose `"\(marker) \(name): "`
    /// themselves — sprigctl's existing line shape).
    public static func describeRelationship(
        of state: BranchSyncState,
        register: VocabularyRegister = .git
    ) -> String {
        switch register {
        case .git: gitRelationship(of: state)
        case .plain: plainRelationship(of: state)
        }
    }

    private static func gitRelationship(of state: BranchSyncState) -> String {
        guard let upstream = state.upstreamShort else { return "no upstream" }
        if state.upstreamGone { return "upstream \(upstream) is gone" }
        switch (state.ahead, state.behind) {
        case (0, 0): return "up to date with \(upstream)"
        case let (a, 0): return "ahead of \(upstream) by \(a)"
        case let (0, b): return "behind \(upstream) by \(b)"
        case let (a, b): return "diverged from \(upstream) (ahead \(a), behind \(b))"
        }
    }

    private static func plainRelationship(of state: BranchSyncState) -> String {
        guard let upstream = state.upstreamShort else {
            return "not linked to a branch on the server"
        }
        if state.upstreamGone {
            return "\(upstream) was deleted on the server"
        }
        switch (state.ahead, state.behind) {
        case (0, 0):
            return "up to date with \(upstream)"
        case let (a, 0):
            return "\(a) commit(s) to send to \(upstream)"
        case let (0, b):
            return "\(b) update(s) to get from \(upstream)"
        case let (a, b):
            return "you and \(upstream) both have new work (git: diverged — ahead \(a), behind \(b))"
        }
    }

    // MARK: - Fast-forward outcomes (pull leg)

    public static func describe(
        _ outcome: FastForwardOutcome,
        register: VocabularyRegister = .git
    ) -> String {
        switch register {
        case .git: gitDescription(of: outcome)
        case .plain: plainDescription(of: outcome)
        }
    }

    private static func gitDescription(of outcome: FastForwardOutcome) -> String {
        switch outcome {
        case let .fastForwarded(from, to):
            "fast-forwarded \(String(from.prefix(8)))..\(String(to.prefix(8)))"
        case .upToDate:
            "nothing to do"
        case let .aheadOnly(ahead):
            "\(ahead) unpushed commit(s); nothing to pull"
        case let .diverged(ahead, behind):
            "needs attention: diverged (ahead \(ahead), behind \(behind))"
        case .noUpstream:
            "no upstream; skipped"
        case .upstreamGone:
            "upstream deleted on remote; skipped"
        case .skippedDirtyWorktree:
            "skipped: uncommitted changes (use --autostash to set them aside)"
        case .skippedCheckedOutElsewhere:
            "skipped: checked out in another worktree"
        case let .failed(reason):
            "failed: \(reason)"
        }
    }

    private static func plainDescription(of outcome: FastForwardOutcome) -> String {
        switch outcome {
        case .fastForwarded:
            "updated your copy to match the server"
        case .upToDate:
            "already up to date"
        case let .aheadOnly(ahead):
            "nothing to get — \(ahead) commit(s) to send"
        case let .diverged(ahead, behind):
            "needs your attention — you and the server both have new work "
                + "(git: diverged — ahead \(ahead), behind \(behind))"
        case .noUpstream:
            "skipped — not linked to a branch on the server"
        case .upstreamGone:
            "skipped — its branch on the server was deleted"
        case .skippedDirtyWorktree:
            "skipped — you have unsaved changes; set them aside first"
        case .skippedCheckedOutElsewhere:
            "skipped — this branch is open in another folder"
        case let .failed(reason):
            "failed: \(reason)"
        }
    }

    // MARK: - Push outcomes (ADR 0071)

    public static func describe(
        _ outcome: PushOutcome,
        register: VocabularyRegister = .git
    ) -> String {
        switch register {
        case .git: gitDescription(of: outcome)
        case .plain: plainDescription(of: outcome)
        }
    }

    private static func gitDescription(of outcome: PushOutcome) -> String {
        switch outcome {
        case let .pushed(branch, upstream, commits):
            "\(branch): pushed \(commits) commit(s) to \(upstream)"
        case let .nothingToPush(branch):
            "\(branch): nothing to push"
        case let .publishedNewUpstream(branch, remote):
            "\(branch): published to \(remote) and now tracks it"
        case let .rejectedNonFastForward(branch):
            "\(branch): rejected — the remote has new commits; pull/resolve first (never forced)"
        case let .noRemotes(branch):
            "\(branch): no remotes configured; nowhere to push"
        case .detachedHEAD:
            "skipped: HEAD is detached (no current branch)"
        case let .failed(reason):
            "failed: \(reason)"
        }
    }

    private static func plainDescription(of outcome: PushOutcome) -> String {
        switch outcome {
        case let .pushed(_, upstream, commits):
            "sent \(commits) commit(s) to \(upstream)"
        case .nothingToPush:
            "nothing to send — the server already has everything"
        case let .publishedNewUpstream(branch, remote):
            "published \(branch) to \(remote); they're now linked"
        case .rejectedNonFastForward:
            "couldn't send — the server has new work; get the latest first (git: non-fast-forward; Sprig never forces)"
        case .noRemotes:
            "no server is set up for this project"
        case .detachedHEAD:
            "skipped — you're not on a branch (git: detached HEAD)"
        case let .failed(reason):
            "failed: \(reason)"
        }
    }

    // MARK: - Pre-flight warnings (ADR 0070)

    public static func describe(
        _ warning: PreflightWarning,
        register: VocabularyRegister = .plain
    ) -> String {
        switch register {
        case .git: gitDescription(of: warning)
        case .plain: plainDescription(of: warning)
        }
    }

    private static func gitDescription(of warning: PreflightWarning) -> String {
        switch warning {
        case let .committingToDefaultBranch(branch, upstream):
            "committing to \(branch) (tracks \(upstream))"
        case let .detachedHEAD(oid):
            "detached HEAD" + (oid.map { " at \(String($0.prefix(8)))" } ?? "")
        case let .largeStagedFileWithoutLFS(path, size, threshold):
            "\(path): \(size) bytes exceeds \(threshold); not LFS-tracked"
        }
    }

    private static func plainDescription(of warning: PreflightWarning) -> String {
        switch warning {
        case let .committingToDefaultBranch(branch, upstream):
            "this commit goes straight to \(branch), which is shared on \(upstream) — "
                + "most teams use a separate branch"
        case let .detachedHEAD(oid):
            "you're not on a branch — work here can be lost; create a branch to keep it"
                + (oid.map { " (git: detached HEAD at \(String($0.prefix(8))))" } ?? " (git: detached HEAD)")
        case let .largeStagedFileWithoutLFS(path, size, threshold):
            "\(path) is \(Self.byteSize(size)) — over the \(Self.byteSize(threshold)) limit; "
                + "track it with LFS so clones stay fast"
        }
    }

    // MARK: - Set-aside outcomes (ADR 0069)

    public static func describe(
        _ outcome: SetAsideOutcome,
        register: VocabularyRegister = .plain
    ) -> String {
        switch (outcome, register) {
        case (.reapplied, .plain):
            "your changes came along to the new branch"
        case (.reapplied, .git):
            "stash reapplied"
        case (.keptInStash, .plain):
            "your changes are safely set aside — bring them back when ready"
        case let (.keptInStash(detail), .git):
            "kept in stash: \(detail)"
        }
    }

    // MARK: - Stale branches (ADR 0073)

    /// The cleanup-banner line for one stale branch.
    public static func describe(
        _ stale: StaleBranch,
        register: VocabularyRegister = .plain
    ) -> String {
        switch register {
        case .git: gitDescription(of: stale)
        case .plain: plainDescription(of: stale)
        }
    }

    private static func gitDescription(of stale: StaleBranch) -> String {
        let upstream = stale.formerUpstream ?? "upstream"
        if stale.safeToDelete {
            return "\(stale.name): \(upstream) is gone; merged — safe to delete"
        }
        if stale.isCurrent {
            return "\(stale.name): \(upstream) is gone; currently checked out"
        }
        return "\(stale.name): \(upstream) is gone; \(stale.unpushedCommitCount) unpushed commit(s)"
    }

    private static func plainDescription(of stale: StaleBranch) -> String {
        if stale.safeToDelete {
            return "\(stale.name) was merged on the server — safe to clean up here"
        }
        if stale.isCurrent {
            return "\(stale.name)'s server branch was removed, but you're on it — "
                + "switch away before cleaning up"
        }
        return "\(stale.name)'s server branch was removed, but it has "
            + "\(stale.unpushedCommitCount) commit(s) that exist nowhere else — "
            + "cleanup keeps a safety copy first"
    }

    // MARK: - Deterministic byte formatting

    /// Locale-free size string: bytes below 1 MiB, otherwise MiB with
    /// one decimal — computed via integer math so the decimal
    /// separator is always `.` regardless of platform locale.
    static func byteSize(_ bytes: Int64) -> String {
        let mebibyte: Int64 = 1024 * 1024
        guard bytes >= mebibyte else { return "\(bytes) bytes" }
        let tenths = (bytes * 10 + mebibyte / 2) / mebibyte
        return "\(tenths / 10).\(tenths % 10) MB"
    }
}
