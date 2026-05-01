// BadgeMapping.swift
//
// Translates `GitCore.Entry` (parsed porcelain-v2 status entries) into
// `BadgeIdentifier` values for the badge trie. The translation is
// deliberately stateless and pure — given an Entry, it picks the badge
// the user should see for that path. Submodule and LFS-specific badges
// are surfaced by callers that have the per-path side-channel
// information (`.gitmodules` walk, `.gitattributes` filter detection);
// porcelain-v2 alone doesn't carry that signal.
//
// Tier 1 portable; depends only on `GitCore` (also Tier 1) and
// `Foundation`.

import Foundation
import GitCore

public extension BadgeIdentifier {
    /// Pick the badge for a single porcelain-v2 entry.
    ///
    /// Mapping rules
    /// -------------
    /// - `untracked` → ``BadgeIdentifier/untracked``
    /// - `ignored`   → ``BadgeIdentifier/ignored``
    /// - `unmerged`  → ``BadgeIdentifier/conflict`` (always; the XY
    ///   variants `UU`/`AA`/`DD`/etc. are all conflicts)
    /// - `ordinary` and `renamed` look at XY:
    ///     - worktree != unmodified → ``BadgeIdentifier/modified``
    ///       (covers `.M`, `MM`, `.D`, etc. — the worktree has
    ///       unstaged changes, which is the most-actionable state)
    ///     - worktree unmodified, index == added → ``BadgeIdentifier/added``
    ///     - worktree unmodified, index ∈ {modified, deleted, typeChanged,
    ///       renamed, copied} → ``BadgeIdentifier/staged``
    ///
    /// What this **doesn't** cover (intentionally):
    /// - LFS pointer files: porcelain-v2 doesn't tell us a path is an
    ///   LFS pointer; that requires a `.gitattributes` walk. The
    ///   `RepoStateStore.apply` site is where any LFS overlay would
    ///   apply, not here.
    /// - Submodule states: porcelain-v2 carries a per-entry submodule
    ///   field, but the SubmoduleKit-driven badges (init-needed /
    ///   out-of-date) require the parent repo's recorded SHA, which
    ///   isn't in this entry. Same comment — the store applies it.
    /// - The `.clean` case isn't producible from a single entry: a
    ///   tracked-and-clean path doesn't *appear* in porcelain-v2
    ///   output at all. RepoStateStore infers `.clean` by absence.
    init(porcelainEntry entry: Entry) {
        switch entry {
        case .untracked: self = .untracked
        case .ignored: self = .ignored
        case .unmerged: self = .conflict
        case let .ordinary(o):
            self = Self.fromXY(o.xy)
        case let .renamed(r):
            self = Self.fromXY(r.xy)
        }
    }

    /// Internal helper: pick a badge from an XY status pair when the
    /// entry kind is ordinary or renamed.
    private static func fromXY(_ xy: StatusXY) -> BadgeIdentifier {
        // Worktree changes win — even if the index *also* has a
        // change, the user has more work to do (stage the worktree
        // delta) so `.modified` is the more actionable signal.
        if xy.worktree != .unmodified {
            return .modified
        }
        // Worktree unmodified — what's queued in the index?
        return switch xy.index {
        case .added:
            // New file already staged.
            .added
        case .modified, .deleted, .typeChanged, .renamed, .copied:
            // Tracked file with a queued change. `.staged` lets the
            // user see what's about to commit at a glance, distinct
            // from the more urgent `.modified` (worktree pending).
            .staged
        case .updatedUnmerged:
            // Defensive: shouldn't reach here for ordinary/renamed
            // (unmerged comes through Entry.unmerged), but if a
            // future git version emits `U.` we route it as a
            // conflict rather than misclassify.
            .conflict
        case .unmodified:
            // X=. and Y=. means the entry shouldn't have surfaced
            // in porcelain-v2 output at all. If it does, we err on
            // the safe side with `.staged` (something queued, exact
            // shape unclear) so the user is prompted to investigate.
            .staged
        }
    }
}
