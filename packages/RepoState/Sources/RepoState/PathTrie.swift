// PathTrie.swift
//
// Path-component trie for badge lookups: maps `URL` to `Value` with
// O(path-depth) insert / remove / lookup. The "nearest-ancestor"
// lookup is the load-bearing one — when FinderSync asks for the badge
// for `/repo/build/out.o` and only `/repo/build/` has an entry (because
// the directory was reported `ignored`), we want to return that entry
// rather than walking the worktree.
//
// Tier 1 portable. No platform APIs, no UI imports. The struct is
// `Sendable` (value type with `Sendable` constraints) so callers can
// thread it through the eventual `RepoState` actor without `@unchecked`.
//
// Performance note (ADR 0021): a 100k-file repo at typical depth ~6
// nests ~6 hash-table walks per lookup. The shell-extension budget is
// <50 ms p99 / <5 ms p50; this comfortably fits even at 1 M paths.
// Benchmarks land alongside the `RepoState` actor in a follow-up PR.

import Foundation

/// Path-component trie. `Value` is the per-path payload; for the badge
/// use case we'll specialize as `PathTrie<BadgeIdentifier>` inside
/// `RepoState`, but the type is generic for testability and reuse.
public struct PathTrie<Value: Sendable>: Sendable {
    private var root = Node()

    /// Number of paths with stored values.
    public private(set) var count: Int = 0

    public init() {}

    // MARK: insert / remove

    /// Insert or replace the value at `path`. Existing intermediate
    /// nodes are reused; new ones are created lazily.
    public mutating func insert(_ value: Value, at path: URL) {
        let components = Self.decompose(path)
        var node = root
        // Walk down, creating nodes as needed. We rebuild from the leaf
        // up at the end so the value-type semantics are preserved
        // without copying every intermediate dictionary.
        var stack: [(Node, String)] = []
        for component in components {
            stack.append((node, component))
            node = node.children[component] ?? Node()
        }
        if node.value == nil {
            count += 1
        }
        node.value = value
        // Rebuild upward.
        for (parent, key) in stack.reversed() {
            var newParent = parent
            newParent.children[key] = node
            node = newParent
        }
        root = node
    }

    /// Remove the value at exact `path`. No-op if the path has no
    /// stored value. Children of `path` are preserved.
    @discardableResult
    public mutating func remove(at path: URL) -> Value? {
        let components = Self.decompose(path)
        var node = root
        var stack: [(Node, String)] = []
        for component in components {
            guard let next = node.children[component] else { return nil }
            stack.append((node, component))
            node = next
        }
        guard let removed = node.value else { return nil }
        node.value = nil
        count -= 1
        // Rebuild upward, pruning empty leaf nodes (no value, no children).
        for (parent, key) in stack.reversed() {
            var newParent = parent
            if node.value == nil, node.children.isEmpty {
                newParent.children.removeValue(forKey: key)
            } else {
                newParent.children[key] = node
            }
            node = newParent
        }
        root = node
        return removed
    }

    /// Drop all stored values. O(1) — just resets the root node.
    public mutating func removeAll() {
        root = Node()
        count = 0
    }

    // MARK: lookup

    /// Exact-path lookup. Returns nil if the path has no stored value,
    /// even if an ancestor does.
    public func value(at path: URL) -> Value? {
        let components = Self.decompose(path)
        var node = root
        for component in components {
            guard let next = node.children[component] else { return nil }
            node = next
        }
        return node.value
    }

    /// Nearest-ancestor lookup. Returns the value at `path` if present,
    /// otherwise the value at the deepest ancestor that has one. Returns
    /// nil when no ancestor has a stored value.
    ///
    /// **The load-bearing badge lookup.** When FinderSync asks for the
    /// badge at `/repo/build/out.o` and only `/repo/build/` has an entry
    /// (inherited from a `.gitignore` rule), this returns the
    /// `build/`-level value.
    public func nearestValue(at path: URL) -> Value? {
        let components = Self.decompose(path)
        var node = root
        var bestValue: Value? = node.value
        for component in components {
            guard let next = node.children[component] else { break }
            node = next
            if let value = node.value {
                bestValue = value
            }
        }
        return bestValue
    }

    /// Collect every stored value along the path from the trie root to
    /// `path`, root-first (closest-to-trie-root first). Useful for
    /// "every ancestor contributes to the answer" patterns —
    /// subscription matching (every subscriber whose root covers this
    /// path), accumulated tags, layered config.
    ///
    /// Distinguished from ``nearestValue(at:)`` which returns a single
    /// value (the deepest ancestor). Use this when callers need *all*
    /// values along the chain, not just the most-specific one.
    ///
    /// Walk stops at the first missing component — ancestors past that
    /// point can't contribute (the path doesn't pass through them), and
    /// values stored at deeper paths than `path` are never collected
    /// (they aren't ancestors of `path`).
    public func ancestorValues(at path: URL) -> [Value] {
        let components = Self.decompose(path)
        var node = root
        var collected: [Value] = []
        if let value = node.value {
            collected.append(value)
        }
        for component in components {
            guard let next = node.children[component] else { break }
            node = next
            if let value = node.value {
                collected.append(value)
            }
        }
        return collected
    }

    // MARK: internals

    /// Decompose a URL into the path components a trie walk uses. We
    /// `standardized` first to fold `..` and `.`, then split on `/`.
    /// Empty components (from leading `/` on POSIX or trailing `/` on
    /// directories) are filtered.
    ///
    /// `URL.pathComponents` deliberately not used here — it includes a
    /// leading "/" entry on absolute paths which would force an empty
    /// first child key, complicating walk logic. Splitting on `/`
    /// directly is portable across macOS and Linux; Windows paths use
    /// `\` as a separator and would need a richer normalization path,
    /// addressed when M2-Win lands.
    static func decompose(_ url: URL) -> [String] {
        let path = url.standardized.path
        return path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Trie node — public-API users never see this directly. Each node
    /// holds an optional value (some interior nodes have no value of
    /// their own; they're just routing) and a child map keyed by path
    /// component string.
    private struct Node {
        var value: Value?
        var children: [String: Node] = [:]
    }
}
