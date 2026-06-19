// RepoSituation — the provider-neutral input to the situation explainer.
//
// Per ADR 0095: the explainer consumes the structured state Sprig
// already has (RepoStatusSummary + porcelain + recent reflog) and
// returns a plain-language explanation plus suggested next verbs.
//
// AIKit is a Tier-1 LEAF package (no cross-package deps — see the
// `tier1Dependencies` map in Package.swift). It therefore CANNOT
// import GitCore's `MidstreamOperation` or TaskWindowKit's
// `RepoStatusSummary`; depending on either would invert tier order
// (TaskWindowKit already depends on GitCore, and pulling those types
// into a leaf would couple AIKit to them). Instead the *caller* — a
// TaskWindowKit view model, a follow-up slice — flattens its rich
// engine types into this small, self-contained snapshot. That keeps
// AIKit testable in isolation and keeps the prompt's input shape
// stable as the engine types evolve.
//
// Tier 1 portable. Pure Foundation. No provider-side concerns.

import Foundation

/// A flattened, provider-neutral snapshot of "where this repo stands"
/// — the input to ``AISituationExplainer``.
///
/// Deliberately small: just the facts the explainer reasons over.
/// The caller maps its engine types (`RepoStatusSummary`,
/// `MidstreamOperation`, reflog lines) onto these plain fields.
public struct RepoSituation: Sendable, Equatable {
    /// Short name of the checked-out branch. `nil` when HEAD is
    /// detached — see ``isDetachedHead``.
    public var branchName: String?

    /// HEAD is detached (not on any branch). Beginners hit this after
    /// checking out a tag or an old commit; it's a common "I'm lost"
    /// trigger ADR 0095 calls out by name.
    public var isDetachedHead: Bool

    /// Short upstream name (`origin/main`); `nil` when none configured.
    public var upstreamName: String?

    /// Configured upstream whose tracking ref no longer exists
    /// (deleted on the remote + pruned). Distinct from "no upstream".
    public var upstreamGone: Bool

    /// Commits the current branch has that its upstream lacks.
    public var ahead: Int

    /// Commits the upstream has that the current branch lacks.
    public var behind: Int

    /// Paths with staged (index) changes.
    public var stagedCount: Int

    /// Paths with unstaged (worktree) changes.
    public var unstagedCount: Int

    /// Untracked paths.
    public var untrackedCount: Int

    /// Paths with merge conflicts (unmerged entries).
    public var conflictedCount: Int

    /// A merge / rebase / cherry-pick / revert / am parked mid-flight,
    /// or ``ParkedOperation/none``.
    public var parkedOperation: ParkedOperation

    /// Most recent reflog lines (newest first), already split into
    /// lines by the caller. Optional context the AI path may use;
    /// the deterministic fallback ignores them. Empty when unknown.
    public var recentReflog: [String]

    public init(
        branchName: String? = nil,
        isDetachedHead: Bool = false,
        upstreamName: String? = nil,
        upstreamGone: Bool = false,
        ahead: Int = 0,
        behind: Int = 0,
        stagedCount: Int = 0,
        unstagedCount: Int = 0,
        untrackedCount: Int = 0,
        conflictedCount: Int = 0,
        parkedOperation: ParkedOperation = .none,
        recentReflog: [String] = []
    ) {
        self.branchName = branchName
        self.isDetachedHead = isDetachedHead
        self.upstreamName = upstreamName
        self.upstreamGone = upstreamGone
        self.ahead = ahead
        self.behind = behind
        self.stagedCount = stagedCount
        self.unstagedCount = unstagedCount
        self.untrackedCount = untrackedCount
        self.conflictedCount = conflictedCount
        self.parkedOperation = parkedOperation
        self.recentReflog = recentReflog
    }

    /// True when the working tree has no staged, unstaged, untracked,
    /// or conflicted entries.
    public var isClean: Bool {
        stagedCount == 0 && unstagedCount == 0
            && untrackedCount == 0 && conflictedCount == 0
    }

    /// True when the branch and its upstream have each moved on
    /// independently — the classic "diverged" state.
    public var isDiverged: Bool {
        ahead > 0 && behind > 0
    }
}

/// A Git operation parked mid-flight. Mirrors GitCore's
/// `MidstreamOperation` cases without importing it (AIKit is a leaf
/// package); the caller maps one onto the other.
public enum ParkedOperation: String, Sendable, Equatable, CaseIterable {
    case none
    case merge
    case rebase
    case cherryPick
    case revert
    case am

    /// User-facing label for the parked operation.
    public var label: String {
        switch self {
        case .none: "no operation"
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        case .am: "patch application (am)"
        }
    }
}
