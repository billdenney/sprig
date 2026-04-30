// RepoStateStore.swift
//
// Actor-isolated wrapper around `PathTrie<BadgeIdentifier>` plus the
// repo-level metadata (branch, stash count). Consumers — the
// FinderSync extension over IPC, sprigctl, future RepoState
// task-window models — talk to this actor to ask "what's the badge
// for path X?" and to publish "here's the latest porcelain-v2
// snapshot, update yourself."
//
// The actor isolation is what lets the watcher thread, the IPC
// dispatch thread, and any task-window query coexist safely on the
// same store. PathTrie itself is a value type, so internal
// concurrent access through the actor is straightforward.
//
// CLAUDE.md "Hard rules": Tier-1, no UI imports, must compile on
// macOS / Linux / Windows. Depends only on Foundation + GitCore.

import Foundation
import GitCore

/// Per-repo in-memory state derived from a porcelain-v2 snapshot.
///
/// One store per watched repo. The agent (`SprigAgent` on macOS, the
/// Windows Service on Windows) owns the lifecycle: create the store
/// on first watch-root registration, refresh via ``apply(_:)`` on
/// every porcelain-v2 snapshot from the watcher tick, query via
/// ``badge(for:)`` on every shell-extension request.
///
/// Path conventions
/// ----------------
/// - ``repoRoot`` is an absolute URL to the worktree root. It's the
///   anchor for all relative paths in incoming `PorcelainV2Status`
///   entries.
/// - ``badge(for:)`` accepts absolute URLs. The store internally
///   stores only paths within `repoRoot`; queries outside the worktree
///   return nil.
public actor RepoStateStore {
    /// Worktree root. Immutable for the lifetime of the store; if the
    /// repo moves, callers should drop and recreate the store.
    public nonisolated let repoRoot: URL

    private var trie: PathTrie<BadgeIdentifier> = .init()
    private var branchInfo: BranchInfo?
    private var stashCountValue: Int?

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot.standardized
    }

    // MARK: ingest

    /// Replace the entire snapshot. Clears the trie, then rebuilds it
    /// from `status.entries`. Branch info and stash count are
    /// overwritten.
    ///
    /// **Whole-snapshot replace, not incremental merge.** Porcelain-v2
    /// emits the *complete* status of the worktree on every call, so
    /// merging would require diffing the previous trie against the
    /// new entries — strictly more work for the same end state. The
    /// trade-off is that paths currently `.clean` (which never appear
    /// in porcelain output) get implicit "no entry → no badge"
    /// treatment, so the shell extension queries rely on
    /// ``badge(for:)`` returning nil to know "this path is clean."
    public func apply(_ status: PorcelainV2Status) {
        trie.removeAll()
        branchInfo = status.branch
        stashCountValue = status.stashCount

        for entry in status.entries {
            let badge = BadgeIdentifier(porcelainEntry: entry)
            let relativePath = Self.relativePath(of: entry)
            let absolute = repoRoot.appendingPathComponent(relativePath)
            trie.insert(badge, at: absolute)
        }
    }

    // MARK: queries

    /// Badge for `path`. Returns nil if no entry exists at the path
    /// or any of its ancestors — by convention, the shell extension
    /// reads nil as "clean / no overlay needed."
    ///
    /// Uses ``PathTrie/nearestValue(at:)`` so that ignored
    /// directories propagate their `.ignored` badge to all children
    /// without needing one entry per child.
    public func badge(for path: URL) -> BadgeIdentifier? {
        trie.nearestValue(at: path.standardized)
    }

    /// Branch metadata from the most recent ``apply(_:)`` snapshot.
    public func branch() -> BranchInfo? {
        branchInfo
    }

    /// Stash count from the most recent ``apply(_:)`` snapshot.
    /// Nil when the snapshot was taken without `--show-stash`.
    public func stashCount() -> Int? {
        stashCountValue
    }

    /// Number of paths currently carrying a badge. Diagnostic only —
    /// useful for sanity-checking trie size growth across snapshots.
    public func entryCount() -> Int {
        trie.count
    }

    // MARK: helpers

    private static func relativePath(of entry: Entry) -> String {
        switch entry {
        case let .ordinary(o): o.path
        case let .renamed(r): r.path
        case let .unmerged(u): u.path
        case let .untracked(path): path
        case let .ignored(path): path
        }
    }
}
