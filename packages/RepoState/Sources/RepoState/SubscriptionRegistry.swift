// SubscriptionRegistry.swift
//
// Tier-1 portable bookkeeping that maps watched roots to subscription
// IDs. The agent's IPC dispatch loop owns one of these; on every
// `IPCSchema.ClientRequest.subscribe`, it calls ``subscribe(roots:)``
// to mint a fresh UUID and remember which roots that subscriber cares
// about. On every unsubscribe (or transport disconnect), it calls
// ``unsubscribe(_:)``. When a refresh detects a badge change at a
// path, the agent calls ``matchingSubscriptions(for:)`` and pushes
// `IPCSchema.AgentEvent.badgeChanged` to each.
//
// Storage: a path-component trie indexed on root paths (so the
// match-path-to-subscriptions lookup is O(path-depth) rather than
// O(subscription-count × roots-per-subscription)). UUID is the public
// identity; the registry holds a reverse map UUID → roots so
// ``unsubscribe(_:)`` can clean up the trie nodes.
//
// Why an actor: the agent runs many concurrent tasks (one per IPC
// connection, one per refresh); Swift 6 requires shared mutable state
// to be isolation-protected. Actor isolation is the cheapest correct
// answer; we don't need re-entrancy here.

import Foundation

/// Maps subscription UUIDs to the watch roots the subscriber cares
/// about, and answers "which subscriptions cover this path?" when a
/// badge changes.
///
/// **Match semantics.** A subscription matches a path when any of its
/// roots is the path itself or an ancestor of the path. So a
/// subscriber registered on `/repo` is notified about
/// `/repo/dir/file.txt`; a subscriber registered on
/// `/repo/dir/file.txt` is also notified (exact match counts);
/// a subscriber registered on `/other` is not.
///
/// **Concurrency.** All public methods are actor-isolated. Callers
/// pass through `await`. The agent will typically own one
/// `SubscriptionRegistry` for the whole process — there's no per-repo
/// scoping; subscriptions can span repos and the index handles that
/// without special-casing.
public actor SubscriptionRegistry {
    /// id → the (standardized) roots the subscription covers. Source
    /// of truth for which subscriptions exist; the trie is a derived
    /// index for fast path-to-ids lookup.
    private var rootsByID: [UUID: [URL]] = [:]

    /// Path → set of subscription IDs that registered that path as a
    /// root. ``matchingSubscriptions(for:)`` walks ancestors of the
    /// query path through this trie, unioning every set it encounters.
    private var index: PathTrie<Set<UUID>> = .init()

    public init() {}

    // MARK: subscribe / unsubscribe

    /// Add a new subscription covering `roots` (recursively). Returns
    /// the freshly-assigned UUID; callers echo it in the
    /// ``IPCSchema/SubscribeAckPayload`` reply.
    ///
    /// Empty `roots` is allowed — it produces a subscription that
    /// never matches, but the agent can still cancel it later. This
    /// keeps the API total: clients that subscribe in two phases
    /// (subscribe-empty, add-roots-later) work without special cases.
    ///
    /// Duplicate roots in the same call are deduplicated silently;
    /// roots are stored in the order first seen.
    @discardableResult
    public func subscribe(roots: [URL]) -> UUID {
        let id = UUID()
        let normalized = Self.deduplicate(roots.map(\.standardized))
        rootsByID[id] = normalized
        for root in normalized {
            var set = index.value(at: root) ?? Set<UUID>()
            set.insert(id)
            index.insert(set, at: root)
        }
        return id
    }

    /// Remove the subscription with id `id`. Returns `true` if a
    /// subscription was removed, `false` if no subscription has that
    /// id (idempotent — agents can call from a transport-close handler
    /// without checking first).
    @discardableResult
    public func unsubscribe(_ id: UUID) -> Bool {
        guard let roots = rootsByID.removeValue(forKey: id) else { return false }
        for root in roots {
            guard var set = index.value(at: root) else { continue }
            set.remove(id)
            if set.isEmpty {
                index.remove(at: root)
            } else {
                index.insert(set, at: root)
            }
        }
        return true
    }

    /// Drop all subscriptions. The agent calls this on shutdown so any
    /// in-flight matchers see the empty state rather than chasing
    /// stale ids.
    public func removeAll() {
        rootsByID.removeAll()
        index.removeAll()
    }

    // MARK: matching

    /// Subscriptions whose roots cover `path`. A subscription matches
    /// when any of its roots is `path` itself or an ancestor of
    /// `path`. Returns ids in sorted order (UUID string ascending) so
    /// callers iterating the result get deterministic ordering — the
    /// agent's push loop benefits from stable ordering when fanning
    /// out events.
    ///
    /// Lookup is O(path-depth) for the trie walk plus O(matches log
    /// matches) for the sort. At the scales we expect (a handful of
    /// subscriptions per agent), the sort is free.
    public func matchingSubscriptions(for path: URL) -> [UUID] {
        let standardized = path.standardized
        let merged = index.ancestorValues(at: standardized).reduce(into: Set<UUID>()) {
            $0.formUnion($1)
        }
        return merged.sorted(by: { $0.uuidString < $1.uuidString })
    }

    // MARK: diagnostics

    /// Number of active subscriptions. Useful for `sprigctl status` /
    /// agent diagnostic dumps.
    public func count() -> Int {
        rootsByID.count
    }

    /// Roots registered for `id`, or nil if no subscription has that
    /// id. Returns roots in the order the caller supplied them
    /// (post-deduplication). Useful for diagnostics and for the
    /// agent's `subscriptionEnded` payload when reporting *why* a
    /// subscription was terminated against which roots.
    public func roots(for id: UUID) -> [URL]? {
        rootsByID[id]
    }

    // MARK: helpers

    /// Stable-order deduplication. We can't use `Array(Set(...))`
    /// because `Set` is unordered; we want the caller's first-seen
    /// order preserved so diagnostics look natural.
    private static func deduplicate(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls where !seen.contains(url) {
            seen.insert(url)
            result.append(url)
        }
        return result
    }
}
