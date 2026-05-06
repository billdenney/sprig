// BadgeChangeBroadcasterSubscriptionEndedTests.swift
//
// Tests for `BadgeChangeBroadcaster.broadcastSubscriptionEnded(reason:)`
// — the producer for `IPCSchema.AgentEvent.subscriptionEnded`. Lives
// in its own file so neither this nor `BadgeChangeBroadcasterTests`
// trips SwiftLint's 400-line `file_length` cap.

import Foundation
import IPCSchema
@testable import RepoState
import Testing

/// Recording sink scoped to this test file. Captures every emitted
/// envelope so assertions can inspect order, count, and contents.
private actor RecordingSink: BadgeEventSink {
    private(set) var emitted: [Envelope<AgentEvent>] = []
    func emit(_ envelope: Envelope<AgentEvent>) async throws {
        emitted.append(envelope)
    }
}

/// Sink that throws on every emit; used to exercise the per-envelope
/// failure-isolation contract.
private struct AlwaysFailingSink: BadgeEventSink {
    struct Boom: Error {}
    func emit(_: Envelope<AgentEvent>) async throws {
        throw Boom()
    }
}

@Suite("BadgeChangeBroadcaster.broadcastSubscriptionEnded — fan-out on agent shutdown")
struct BroadcastSubscriptionEndedTests {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    @Test("with no active subscriptions, broadcastSubscriptionEnded emits nothing")
    func noSubscriptionsNoEmissions() async {
        let registry = SubscriptionRegistry()
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let result = await broadcaster.broadcastSubscriptionEnded(reason: "agent_shutdown")
        #expect(result.emitted == 0)
        #expect(result.failed == 0)
        #expect(await sink.emitted.isEmpty)
    }

    @Test("emits one envelope per active subscription, with the supplied reason")
    func emitsOnePerSubscription() async {
        let registry = SubscriptionRegistry()
        let id1 = await registry.subscribe(roots: [url("/a")])
        let id2 = await registry.subscribe(roots: [url("/b")])
        let id3 = await registry.subscribe(roots: [url("/c")])
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let result = await broadcaster.broadcastSubscriptionEnded(reason: "agent_shutdown")
        #expect(result.emitted == 3)
        #expect(result.failed == 0)

        let emitted = await sink.emitted
        #expect(emitted.count == 3)
        // Every envelope must be a subscriptionEnded; the union of
        // subscriptionIds must equal the registry's active set.
        var seenIDs: Set<UUID> = []
        for envelope in emitted {
            guard case let .subscriptionEnded(payload) = envelope.message else {
                Issue.record("expected .subscriptionEnded, got \(envelope.message)")
                continue
            }
            #expect(payload.reason == "agent_shutdown", "wire-stable reason must round-trip")
            seenIDs.insert(payload.subscriptionId)
        }
        #expect(seenIDs == Set([id1, id2, id3]))
    }

    @Test("sink failures are isolated per-subscription; broadcaster keeps going")
    func failuresAreIsolated() async {
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/a")])
        _ = await registry.subscribe(roots: [url("/b")])
        let sink = AlwaysFailingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        let result = await broadcaster.broadcastSubscriptionEnded(reason: "internal")
        // Both attempted; both failed; the broadcaster reported them
        // truthfully without aborting after the first throw.
        #expect(result.emitted == 0)
        #expect(result.failed == 2)
    }

    @Test("reason string is opaque — non-canonical values pass through unchanged")
    func reasonIsOpaque() async {
        // The broadcaster doesn't validate the reason string; it's the
        // wire-stable contract from `IPCSchema.SubscriptionEndedPayload`'s
        // doc-comment, but enforcement is the producer's call. A
        // non-canonical value should still flow through verbatim.
        let registry = SubscriptionRegistry()
        _ = await registry.subscribe(roots: [url("/x")])
        let sink = RecordingSink()
        let broadcaster = BadgeChangeBroadcaster(registry: registry, sink: sink)

        _ = await broadcaster.broadcastSubscriptionEnded(reason: "totally_made_up")
        let emitted = await sink.emitted
        #expect(emitted.count == 1)
        guard case let .subscriptionEnded(payload) = emitted.first?.message else {
            Issue.record("expected .subscriptionEnded")
            return
        }
        #expect(payload.reason == "totally_made_up")
    }
}
