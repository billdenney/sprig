import Foundation
import GitCore
import IPCSchema
@testable import RepoState
import Testing

// MARK: - Test sinks (file-private to avoid nested-type lint)

/// Sink failure used by ``AlwaysFailingSink`` and ``FlakySink``.
private struct SinkBoom: Error {}

/// Recording sink that captures every envelope it's asked to emit.
/// Actor-isolated so concurrent calls don't violate Sendable.
private actor RecordingSink: BadgeEventSink {
    private(set) var emitted: [Envelope<AgentEvent>] = []

    func emit(_ envelope: Envelope<AgentEvent>) async throws {
        emitted.append(envelope)
    }
}

/// Sink that always throws; used to prove failure isolation.
private struct AlwaysFailingSink: BadgeEventSink {
    func emit(_: Envelope<AgentEvent>) async throws {
        throw SinkBoom()
    }
}

/// Sink whose first N emits throw, then succeed. Verifies the
/// broadcaster keeps going past failures.
private actor FlakySink: BadgeEventSink {
    private var remainingFailures: Int
    private(set) var emitted: [Envelope<AgentEvent>] = []

    init(failuresBeforeSuccess: Int) {
        remainingFailures = failuresBeforeSuccess
    }

    func emit(_ envelope: Envelope<AgentEvent>) async throws {
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw SinkBoom()
        }
        emitted.append(envelope)
    }
}

@Suite("BadgeChangeBroadcaster — fan PathBadgeChange out to AgentEvent envelopes")
struct BadgeChangeBroadcasterTests {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardized
    }

    // MARK: empty inputs

    @Test("broadcast on an empty change list emits nothing")
    func emptyChangesEmitsNothing() async {
        let registry = SubscriptionRegistry()
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let result = await broadcaster.broadcast([])
        #expect(result.emitted == 0)
        #expect(result.failed == 0)
        #expect(await sink.emitted.isEmpty)
    }

    @Test("broadcast with no subscribers emits nothing")
    func noSubscribersEmitsNothing() async {
        let registry = SubscriptionRegistry()
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let changes = [
            PathBadgeChange(path: url("/repo/x.txt"), before: nil, after: .untracked)
        ]
        let result = await broadcaster.broadcast(changes)
        #expect(result.emitted == 0)
        #expect(await sink.emitted.isEmpty)
    }

    // MARK: single subscriber, one event per change

    @Test("a single subscriber receives one envelope per change")
    func singleSubscriberSingleEvent() async {
        let registry = SubscriptionRegistry()
        let id = await registry.subscribe(roots: [url("/repo")])
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let changes = [
            PathBadgeChange(path: url("/repo/a.txt"), before: nil, after: .untracked),
            PathBadgeChange(path: url("/repo/b.txt"), before: .untracked, after: .added)
        ]
        let result = await broadcaster.broadcast(changes)
        #expect(result.emitted == 2)
        #expect(result.failed == 0)

        let emitted = await sink.emitted
        #expect(emitted.count == 2)
        for envelope in emitted {
            guard case let .badgeChanged(payload) = envelope.message else {
                Issue.record("expected badgeChanged, got \(envelope.message)")
                return
            }
            #expect(payload.subscriptionId == id)
        }
    }

    // MARK: payload encoding

    @Test("payload carries the after-state badge rawValue (or nil for cleared)")
    func payloadCarriesAfterBadge() async {
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/repo")])
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let changes = [
            // newly badged
            PathBadgeChange(path: url("/repo/a.txt"), before: nil, after: .modified),
            // became clean
            PathBadgeChange(path: url("/repo/b.txt"), before: .untracked, after: nil),
            // transitioned
            PathBadgeChange(path: url("/repo/c.txt"), before: .untracked, after: .added)
        ]
        _ = await broadcaster.broadcast(changes)

        let emitted = await sink.emitted
        let badgeByPath: [String: String?] = emitted.reduce(into: [:]) { acc, env in
            if case let .badgeChanged(payload) = env.message {
                acc[payload.path] = payload.badge
            }
        }
        #expect(badgeByPath["/repo/a.txt"] == .some("modified"))
        #expect(badgeByPath["/repo/b.txt"] == .some(nil)) // explicit nil → "clear cache"
        #expect(badgeByPath["/repo/c.txt"] == .some("added"))
    }

    @Test("payload encodes the absolute path via URL.path (POSIX)")
    func payloadCarriesPath() async {
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/repo")])
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let changes = [
            PathBadgeChange(path: url("/repo/dir/file.txt"), before: nil, after: .untracked)
        ]
        _ = await broadcaster.broadcast(changes)

        let emitted = await sink.emitted
        #expect(emitted.count == 1)
        guard case let .badgeChanged(payload) = emitted[0].message else {
            Issue.record("expected badgeChanged")
            return
        }
        #expect(payload.path == "/repo/dir/file.txt")
    }

    // MARK: fan-out across multiple subscribers

    @Test("multiple subscribers on the same root each receive their own envelope per change")
    func multipleSubscribersPerChange() async {
        let registry = SubscriptionRegistry()
        let a = await registry.subscribe(roots: [url("/repo")])
        let b = await registry.subscribe(roots: [url("/repo")])
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let changes = [
            PathBadgeChange(path: url("/repo/x.txt"), before: nil, after: .untracked)
        ]
        let result = await broadcaster.broadcast(changes)
        // 1 change × 2 subscribers = 2 envelopes
        #expect(result.emitted == 2)

        let emitted = await sink.emitted
        let subscriptionIDs: Set<UUID> = Set(emitted.compactMap {
            if case let .badgeChanged(payload) = $0.message {
                return payload.subscriptionId
            }
            return nil
        })
        #expect(subscriptionIDs == Set([a, b]))
    }

    @Test("nested-root subscribers both receive envelopes for a deep-descendant change")
    func nestedRootsBothFire() async {
        let registry = SubscriptionRegistry()
        // Subscriber A watches /repo (covers all); B watches /repo/dir.
        let a = await registry.subscribe(roots: [url("/repo")])
        let b = await registry.subscribe(roots: [url("/repo/dir")])
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let changes = [
            PathBadgeChange(path: url("/repo/dir/file.txt"), before: nil, after: .untracked)
        ]
        _ = await broadcaster.broadcast(changes)

        let emitted = await sink.emitted
        let subIDs = emitted.compactMap {
            if case let .badgeChanged(payload) = $0.message {
                return payload.subscriptionId
            }
            return nil
        }
        #expect(Set(subIDs) == Set([a, b]))
    }

    @Test("a subscriber whose root doesn't cover a path is NOT notified")
    func nonMatchingSubscriberSkipped() async {
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/repo-a")])
        let coveringID = await registry.subscribe(roots: [url("/repo-b")])
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let changes = [
            PathBadgeChange(path: url("/repo-b/x.txt"), before: nil, after: .untracked)
        ]
        _ = await broadcaster.broadcast(changes)

        let emitted = await sink.emitted
        #expect(emitted.count == 1)
        if case let .badgeChanged(payload) = emitted[0].message {
            #expect(payload.subscriptionId == coveringID)
        } else {
            Issue.record("expected badgeChanged")
        }
    }

    // MARK: failure isolation

    @Test("a sink that always throws produces failures but doesn't abort")
    func alwaysFailingSinkCountsFailures() async {
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/repo")])
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: AlwaysFailingSink())

        let changes = [
            PathBadgeChange(path: url("/repo/a"), before: nil, after: .untracked),
            PathBadgeChange(path: url("/repo/b"), before: nil, after: .untracked),
            PathBadgeChange(path: url("/repo/c"), before: nil, after: .untracked)
        ]
        let result = await broadcaster.broadcast(changes)
        #expect(result.emitted == 0)
        #expect(result.failed == 3)
    }

    @Test("a flaky sink that fails twice then succeeds: broadcast keeps going past failures")
    func flakySinkContinuesAfterFailure() async {
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/repo")])
        let sink = FlakySink(failuresBeforeSuccess: 2)
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let changes = [
            PathBadgeChange(path: url("/repo/a"), before: nil, after: .untracked),
            PathBadgeChange(path: url("/repo/b"), before: nil, after: .untracked),
            PathBadgeChange(path: url("/repo/c"), before: nil, after: .untracked),
            PathBadgeChange(path: url("/repo/d"), before: nil, after: .untracked)
        ]
        let result = await broadcaster.broadcast(changes)
        #expect(result.failed == 2)
        #expect(result.emitted == 2)
        #expect(await sink.emitted.count == 2)
    }

    // MARK: end-to-end with applyAndDiff

    @Test("end-to-end: applyAndDiff feeds the broadcaster, sink sees real envelopes")
    func endToEndApplyAndDiff() async {
        // Realistic agent loop: store + registry + broadcaster fed by
        // two porcelain snapshots, asserting every envelope flowed.
        let root = makeBroadcastTestRoot()
        let store = RepoStateStore(repoRoot: root)
        let registry = SubscriptionRegistry()
        let subID = await registry.subscribe(roots: [root])
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        // Snapshot 1 — one untracked file.
        let r1 = await broadcaster.broadcast(
            store.applyAndDiff(makeBroadcastSnapshot1())
        )
        #expect(r1.emitted == 1)

        // Snapshot 2 — a.txt is now staged, b.txt newly appeared.
        let r2 = await broadcaster.broadcast(
            store.applyAndDiff(makeBroadcastSnapshot2())
        )
        #expect(r2.emitted == 2)

        await assertEndToEndEnvelopes(sink: sink, root: root, expectedSubscriber: subID)
    }
}

// MARK: - End-to-end helpers (file-scope to keep struct body under 250 lines)

private func makeBroadcastTestRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sprig-broadcast-\(UUID().uuidString)")
        .standardized
}

private func makeBroadcastSnapshot1() -> PorcelainV2Status {
    PorcelainV2Status(
        branch: nil,
        stashCount: nil,
        entries: [.untracked(path: "a.txt")]
    )
}

private func makeBroadcastSnapshot2() -> PorcelainV2Status {
    let zero = String(repeating: "0", count: 40)
    return PorcelainV2Status(
        branch: nil,
        stashCount: nil,
        entries: [
            .ordinary(Ordinary(
                xy: StatusXY(index: .added, worktree: .unmodified),
                submodule: .notSubmodule,
                modeHead: 0o100644,
                modeIndex: 0o100644,
                modeWorktree: 0o100644,
                hashHead: zero,
                hashIndex: zero,
                path: "a.txt"
            )),
            .untracked(path: "b.txt")
        ]
    )
}

private func assertEndToEndEnvelopes(
    sink: RecordingSink,
    root: URL,
    expectedSubscriber: UUID
) async {
    let emitted = await sink.emitted
    #expect(emitted.count == 3) // 1 from snap1 + 2 from snap2
    for envelope in emitted {
        guard case let .badgeChanged(payload) = envelope.message else {
            Issue.record("expected badgeChanged")
            continue
        }
        #expect(payload.subscriptionId == expectedSubscriber)
    }
    let snap2Envs = Array(emitted.suffix(2))
    let byPath: [String: String?] = snap2Envs.reduce(into: [:]) { acc, env in
        if case let .badgeChanged(payload) = env.message {
            acc[payload.path] = payload.badge
        }
    }
    let aPath = root.appendingPathComponent("a.txt").standardized.path
    let bPath = root.appendingPathComponent("b.txt").standardized.path
    #expect(byPath[aPath] == .some("added"))
    #expect(byPath[bPath] == .some("untracked"))
}
