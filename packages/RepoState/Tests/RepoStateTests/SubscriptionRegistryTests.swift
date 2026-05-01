import Foundation
@testable import RepoState
import Testing

@Suite("SubscriptionRegistry — root-to-id mapping for AgentEvent fan-out")
struct SubscriptionRegistryTests {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    // MARK: subscribe + match

    @Test("subscribe returns a fresh UUID and the registry counts it")
    func subscribeAssignsFreshID() async {
        let registry = SubscriptionRegistry()
        let id1 = await registry.subscribe(roots: [url("/repo")])
        let id2 = await registry.subscribe(roots: [url("/repo")])
        #expect(id1 != id2)
        #expect(await registry.count() == 2)
    }

    @Test("matchingSubscriptions returns the subscriber when the query path is the exact root")
    func matchOnExactRoot() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo")])
        #expect(await registry.matchingSubscriptions(for: url("/repo")) == [id])
    }

    @Test("matchingSubscriptions returns the subscriber when the query path is a descendant of a root")
    func matchOnDescendant() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo")])
        #expect(await registry.matchingSubscriptions(for: url("/repo/dir/file.txt")) == [id])
    }

    @Test("matchingSubscriptions returns [] when no root covers the path")
    func noMatchOutsideRoots() async {
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/repo")])
        #expect(await registry.matchingSubscriptions(for: url("/elsewhere/x.txt")) == [])
    }

    @Test("a subscriber is NOT matched when its root is a descendant of the query path")
    func rootDeeperThanPathDoesNotMatch() async {
        // Subscribe to /repo/dir/file.txt; query at /repo. /repo is an
        // ancestor of the root, not the other way round — no match.
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/repo/dir/file.txt")])
        #expect(await registry.matchingSubscriptions(for: url("/repo")) == [])
    }

    // MARK: multi-root + overlapping

    @Test("a subscriber with multiple roots matches when any one root covers the path")
    func multiRootMatchesAny() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo-a"), url("/repo-b")])
        #expect(await registry.matchingSubscriptions(for: url("/repo-a/file")) == [id])
        #expect(await registry.matchingSubscriptions(for: url("/repo-b/file")) == [id])
        #expect(await registry.matchingSubscriptions(for: url("/repo-c/file")) == [])
    }

    @Test("a subscriber whose two roots both cover the same path appears exactly once")
    func multiRootDeduplicatedAtMatch() async {
        // /repo and /repo/dir both cover /repo/dir/file.txt — the same
        // subscription must not appear twice in the match list.
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo"), url("/repo/dir")])
        #expect(
            await registry.matchingSubscriptions(for: url("/repo/dir/file.txt"))
                == [id]
        )
    }

    @Test("multiple subscribers on the same root are all returned")
    func multipleSubscribersSameRoot() async {
        let registry = SubscriptionRegistry()
        let a = await registry.subscribe(roots: [url("/repo")])
        let b = await registry.subscribe(roots: [url("/repo")])
        let matches = await registry.matchingSubscriptions(for: url("/repo/file.txt"))
        #expect(matches.count == 2)
        #expect(Set(matches) == Set([a, b]))
    }

    @Test("subscribers at nested roots both match a deep-descendant query")
    func nestedRootsBothMatch() async {
        // A subscribes /repo, B subscribes /repo/dir. A query at
        // /repo/dir/file.txt should fire both.
        let registry = SubscriptionRegistry()
        let a = await registry.subscribe(roots: [url("/repo")])
        let b = await registry.subscribe(roots: [url("/repo/dir")])
        let matches = await registry.matchingSubscriptions(for: url("/repo/dir/file.txt"))
        #expect(Set(matches) == Set([a, b]))
    }

    @Test("matchingSubscriptions returns ids in deterministic (sorted) order")
    func matchOrderIsStable() async {
        let registry = SubscriptionRegistry()
        // Subscribe in random-ish order; expect output sorted by UUID
        // string regardless.
        var ids: [UUID] = []
        for _ in 0 ..< 10 {
            await ids.append(registry.subscribe(roots: [url("/repo")]))
        }
        let matches = await registry.matchingSubscriptions(for: url("/repo/file"))
        #expect(matches == matches.sorted(by: { $0.uuidString < $1.uuidString }))
        #expect(Set(matches) == Set(ids))
    }

    // MARK: unsubscribe

    @Test("unsubscribe removes the subscription from future matches")
    func unsubscribeRemovesMatches() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo")])
        #expect(await registry.matchingSubscriptions(for: url("/repo/file")) == [id])
        let removed = await registry.unsubscribe(id)
        #expect(removed)
        #expect(await registry.matchingSubscriptions(for: url("/repo/file")) == [])
        #expect(await registry.count() == 0)
    }

    @Test("unsubscribe of an unknown id returns false (idempotent)")
    func unsubscribeUnknownIDReturnsFalse() async {
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/repo")])
        let result = await registry.unsubscribe(UUID())
        #expect(!result)
        #expect(await registry.count() == 1)
    }

    @Test("unsubscribe of one subscriber leaves co-located peers intact")
    func unsubscribeOneOfMany() async {
        let registry = SubscriptionRegistry()
        let a = await registry.subscribe(roots: [url("/repo")])
        let b = await registry.subscribe(roots: [url("/repo")])
        _ = await registry.unsubscribe(a)
        let matches = await registry.matchingSubscriptions(for: url("/repo/file"))
        #expect(matches == [b])
    }

    @Test("unsubscribe cleans up the index across all of its roots")
    func unsubscribeCleansAllRoots() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo-a"), url("/repo-b")])
        _ = await registry.unsubscribe(id)
        #expect(await registry.matchingSubscriptions(for: url("/repo-a/x")) == [])
        #expect(await registry.matchingSubscriptions(for: url("/repo-b/x")) == [])
    }

    @Test("removeAll empties the registry; subsequent matches return []")
    func removeAllResets() async {
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/repo")])
        _ = await registry.subscribe(roots: [url("/other")])
        await registry.removeAll()
        #expect(await registry.count() == 0)
        #expect(await registry.matchingSubscriptions(for: url("/repo/file")) == [])
    }

    // MARK: empty + dedup edge cases

    @Test("subscribing with empty roots yields a valid id that never matches")
    func emptyRootsSubscriptionMatchesNothing() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [])
        #expect(await registry.count() == 1)
        #expect(await registry.matchingSubscriptions(for: url("/anywhere")) == [])
        // Still cancellable.
        #expect(await registry.unsubscribe(id))
    }

    @Test("duplicate roots in one subscribe call are deduped (insertion order preserved)")
    func duplicateRootsDeduped() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo"), url("/repo")])
        let stored = await registry.roots(for: id)
        #expect(stored?.count == 1)
        #expect(stored?.first?.standardized == url("/repo").standardized)
    }

    // MARK: diagnostics

    @Test("roots(for:) returns the standardized roots for a known id, nil otherwise")
    func rootsLookup() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo/./dir")])
        let stored = await registry.roots(for: id)
        // Standardization folds the `./` segment.
        #expect(stored?.first?.path == url("/repo/dir").standardized.path)
        #expect(await registry.roots(for: UUID()) == nil)
    }

    @Test("count tracks subscribe / unsubscribe across many ids")
    func countTracksOps() async {
        let registry = SubscriptionRegistry()
        var ids: [UUID] = []
        for _ in 0 ..< 5 {
            await ids.append(registry.subscribe(roots: [url("/repo")]))
        }
        #expect(await registry.count() == 5)
        for id in ids.prefix(3) {
            _ = await registry.unsubscribe(id)
        }
        #expect(await registry.count() == 2)
    }

    // MARK: path normalization

    @Test("matchingSubscriptions normalizes the query path so . and .. fold")
    func matchPathIsNormalized() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo")])
        #expect(
            await registry.matchingSubscriptions(for: url("/repo/./dir/../file"))
                == [id]
        )
    }

    @Test("subscribe normalizes roots so equivalent paths share a trie node")
    func rootIsNormalizedAtSubscribe() async {
        let registry = SubscriptionRegistry()
        // /repo/./dir and /repo/dir are the same after standardization;
        // a query under either form should match.
        let id = await registry.subscribe(roots: [url("/repo/./dir")])
        #expect(await registry.matchingSubscriptions(for: url("/repo/dir/file")) == [id])
    }
}
