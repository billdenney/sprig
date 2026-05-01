// BadgeDiff.swift
//
// Pure utility for "what badges changed between two snapshots?" — the
// piece that lets the agent emit `IPCSchema.AgentEvent.badgeChanged`
// only for paths whose badge actually changed, instead of re-pushing
// every entry on every refresh.
//
// Composes with:
// - `RepoStatusRefresher` — runs `git status --porcelain=v2` and
//   produces a fresh snapshot per tick.
// - `RepoStateStore.applyAndDiff(_:)` — the atomic capture-apply-
//   capture-diff path that callers actually invoke (this file is the
//   inner pure step it delegates to).
// - `SubscriptionRegistry.matchingSubscriptions(for:)` — given a
//   changed path, the subscribers to fan the event out to.
//
// Tier-1 portable; no platform APIs, no `#if os(...)`. Inputs and
// outputs are plain Foundation types so this is hermetically testable
// without spawning git.

import Foundation

/// One path's badge transition between two snapshots.
///
/// Either of `before` / `after` may be nil (newly badged → before is
/// nil; became clean → after is nil). When both are non-nil, they
/// differ — paths whose badge is unchanged never appear in a diff.
public struct PathBadgeChange: Sendable, Equatable {
    /// Absolute path whose badge changed.
    public var path: URL

    /// Badge in the prior snapshot, or nil if the path had no entry
    /// (path was clean / unbadged).
    public var before: BadgeIdentifier?

    /// Badge in the new snapshot, or nil if the path no longer has an
    /// entry (path is now clean / unbadged).
    public var after: BadgeIdentifier?

    public init(path: URL, before: BadgeIdentifier?, after: BadgeIdentifier?) {
        self.path = path
        self.before = before
        self.after = after
    }
}

/// Pure-function badge-diff utility. Stateless namespace; callers
/// reach for the static method.
public enum BadgeDiff {
    /// The set of paths whose badge changed between `before` and
    /// `after`. Returned sorted by path so callers (and tests) get
    /// deterministic ordering.
    ///
    /// **Inclusion rules.** A path appears in the result iff
    /// `before[path] != after[path]`. The resulting `PathBadgeChange`
    /// carries both sides so callers don't need to look the prior
    /// state up themselves — the agent's emit step uses `after` for
    /// the `BadgeChangedPayload.badge` field directly.
    ///
    /// **First-refresh semantics.** When `before` is empty (no prior
    /// snapshot exists), every path in `after` appears as a change
    /// from nil → its-current-badge. Callers that want to suppress
    /// the initial flurry should special-case "this is the first
    /// refresh of this repo since agent start" upstream.
    public static func compute(
        before: [URL: BadgeIdentifier],
        after: [URL: BadgeIdentifier]
    ) -> [PathBadgeChange] {
        var result: [PathBadgeChange] = []
        let allPaths = Set(before.keys).union(after.keys)
        for path in allPaths {
            let priorBadge = before[path]
            let nextBadge = after[path]
            if priorBadge != nextBadge {
                result.append(PathBadgeChange(path: path, before: priorBadge, after: nextBadge))
            }
        }
        // URL.path is the stable, comparable form. Sorting by URL
        // directly compares absoluteString which differs in trailing-
        // slash handling for directories; `.path` is what we standardize
        // on elsewhere in the package.
        result.sort(by: { $0.path.path < $1.path.path })
        return result
    }
}
