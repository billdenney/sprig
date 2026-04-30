// BadgeIdentifier.swift
//
// The wire-stable enumeration of overlay-badge states Sprig draws on
// tracked files. Lives in RepoState (Tier 1, portable) because both the
// macOS FinderSync extension and the Windows Explorer shell extension
// need to consume the same identifiers — the rendering pipelines differ
// per platform but the data model doesn't.
//
// ADR 0019 ratifies the 10-state set. ADR 0020 covers the menu surface.
// `docs/architecture/shell-integration.md` documents the per-platform
// rendering. CLAUDE.md "Hard rules" forbid AppKit / SwiftUI imports here,
// which is fine — this file is pure data.

import Foundation

/// One of ten overlay-badge states a tracked path can carry.
///
/// Identifiers are wire-stable: their `rawValue` strings appear in
/// `IPCSchema` envelopes between the agent and the shell extension, and
/// in registry / asset-catalog identifiers on disk. Renaming a case
/// without a migration is a breaking change.
///
/// The 10 cases mirror the table in
/// `docs/architecture/shell-integration.md` "Badge set (ADR 0019)" —
/// keep that table and this enum in lockstep.
public enum BadgeIdentifier: String, Sendable, Hashable, CaseIterable {
    /// Tracked, matches HEAD. Default for everything that's not changed.
    case clean

    /// Tracked file differs from HEAD in the worktree.
    case modified

    /// New file already staged in the index.
    case added

    /// Tracked file modified and staged. Distinct from `.modified` so
    /// the at-a-glance answer to "what's queued for commit?" is visible
    /// without inspecting the index.
    case staged

    /// Not in the index, not ignored.
    case untracked

    /// Unmerged path. **Always wins** against any other state; see
    /// ``priority`` and ADR 0019 "Conflict always wins."
    case conflict

    /// Matches `.gitignore`. Suppressed at the "Minimal" reveal level
    /// (default is "Rich").
    case ignored

    /// Git-LFS pointer file that hasn't been smudged yet. Surfaced even
    /// when the file would otherwise be `.clean`, so users notice they
    /// don't have the real bytes locally.
    case lfsPointer = "lfs-pointer"

    /// Submodule directory exists in the worktree but `git submodule
    /// init` hasn't been run for it yet.
    case submoduleInitNeeded = "submodule-init-needed"

    /// Submodule HEAD differs from the SHA the super-repo records as
    /// "the version we depend on." Either action is reasonable —
    /// `git submodule update` to revert to the recorded SHA, or
    /// `git add <submodule>` to record the new tip.
    case submoduleOutOfDate = "submodule-out-of-date"

    /// Higher priority overrides lower when a path plausibly carries
    /// multiple states.
    ///
    /// **Conflict always wins** — even a `modified` conflict file shows
    /// the conflict badge so the user sees the actionable state first.
    /// Submodule states rank above ordinary file states because a
    /// submodule directory's render is *defined* by the submodule's
    /// state; ordinary tracked-file diff doesn't apply. The remaining
    /// ordering follows "what's the most actionable thing here": fix
    /// conflicts, finish the in-progress staged change, deal with
    /// untracked files, then fall through to the ambient states (lfs-
    /// pointer warning > ignored > clean).
    ///
    /// Priorities are spaced by 5 with room to insert future states
    /// without reshuffling the whole ladder.
    public var priority: Int {
        switch self {
        case .conflict: 100
        case .submoduleOutOfDate: 90
        case .submoduleInitNeeded: 85
        case .modified: 70
        case .staged: 65
        case .added: 60
        case .untracked: 50
        case .lfsPointer: 40
        case .ignored: 20
        case .clean: 10
        }
    }

    /// True if this identifier should be drawn at `level`.
    ///
    /// Per ADR 0019: Minimal 5 / Rich 8 (default) / Full 10. The
    /// "minimal" set covers the most-actionable states; "rich" adds
    /// `added`, `ignored`, and `lfs-pointer`; "full" adds the two
    /// submodule states.
    public func isVisible(at level: BadgeRevealLevel) -> Bool {
        switch level {
        case .full:
            true
        case .rich:
            self != .submoduleInitNeeded && self != .submoduleOutOfDate
        case .minimal:
            switch self {
            case .clean, .modified, .staged, .untracked, .conflict: true
            default: false
            }
        }
    }
}

/// User-selectable reveal levels for the badge set, per ADR 0019.
///
/// The shell extension queries `BadgeIdentifier.isVisible(at:)` before
/// asking the agent to draw — so the user's chosen level filters at
/// the rendering boundary, not at the data-model boundary. RepoState
/// always knows the true state; the extension just doesn't always
/// surface it.
public enum BadgeRevealLevel: String, Sendable, Hashable, CaseIterable {
    /// 5 states: clean, modified, staged, untracked, conflict.
    case minimal

    /// 8 states: minimal + added, ignored, lfs-pointer. **Default.**
    case rich

    /// All 10 states.
    case full

    public static let `default`: BadgeRevealLevel = .rich
}

public extension BadgeIdentifier {
    /// Highest-priority badge among `candidates`. Returns nil for the
    /// empty case so callers can default to `.clean` (or omit the
    /// badge entirely) explicitly. Conflict, the highest-priority
    /// state, sorts to the top of any non-empty candidate set.
    static func highestPriority(of candidates: some Sequence<BadgeIdentifier>) -> BadgeIdentifier? {
        candidates.max(by: { $0.priority < $1.priority })
    }
}
