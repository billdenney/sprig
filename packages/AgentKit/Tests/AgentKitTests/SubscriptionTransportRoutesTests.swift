// SubscriptionTransportRoutesTests.swift
//
// Unit tests for the UUID → Transport lookup table that backs
// `RoutedBadgeEventSink`. Uses `hasMapping` / `isMapping` accessors
// rather than `transport(for:)` so the existential `any Transport?`
// doesn't have to cross actor boundaries (Swift 6 strict-concurrency
// quirk; see the doc-comment on `SubscriptionTransportRoutes.transport(for:)`).

@testable import AgentKit
import Foundation
import Testing
import TransportKit

@Suite("SubscriptionTransportRoutes — UUID → Transport mapping")
struct SubscriptionTransportRoutesTests {
    @Test("freshly constructed routes table is empty")
    func startsEmpty() async {
        let routes = SubscriptionTransportRoutes()
        #expect(await routes.count() == 0)
        #expect(await routes.hasMapping(for: UUID()) == false)
    }

    @Test("register associates a UUID with a transport")
    func registerStoresMapping() async {
        let routes = SubscriptionTransportRoutes()
        let pair = InProcessTransportPair.connected()
        defer { Task { await pair.agentEnd.close() } }

        let id = UUID()
        await routes.register(id, transport: pair.agentEnd)

        #expect(await routes.hasMapping(for: id))
        #expect(await routes.isMapping(id, to: pair.agentEnd))
        #expect(await routes.count() == 1)
    }

    @Test("two distinct ids map to two distinct transports")
    func twoIdsTwoTransports() async {
        let routes = SubscriptionTransportRoutes()
        let pairA = InProcessTransportPair.connected()
        let pairB = InProcessTransportPair.connected()
        defer {
            Task {
                await pairA.agentEnd.close()
                await pairB.agentEnd.close()
            }
        }

        let idA = UUID()
        let idB = UUID()
        await routes.register(idA, transport: pairA.agentEnd)
        await routes.register(idB, transport: pairB.agentEnd)

        #expect(await routes.count() == 2)
        #expect(await routes.isMapping(idA, to: pairA.agentEnd))
        #expect(await routes.isMapping(idB, to: pairB.agentEnd))
        // Cross-mappings must NOT match — id A is not on transport B.
        #expect(await routes.isMapping(idA, to: pairB.agentEnd) == false)
        #expect(await routes.isMapping(idB, to: pairA.agentEnd) == false)
    }

    @Test("unregister drops the mapping; subsequent lookups return false")
    func unregisterDropsMapping() async {
        let routes = SubscriptionTransportRoutes()
        let pair = InProcessTransportPair.connected()
        defer { Task { await pair.agentEnd.close() } }

        let id = UUID()
        await routes.register(id, transport: pair.agentEnd)
        await routes.unregister(id)
        #expect(await routes.hasMapping(for: id) == false)
        #expect(await routes.count() == 0)
    }

    @Test("unregister of an unknown id is a no-op")
    func unregisterUnknownIsNoOp() async {
        let routes = SubscriptionTransportRoutes()
        await routes.unregister(UUID())
        #expect(await routes.count() == 0)
    }

    @Test("unregisterAll(transport:) drops every mapping for that transport")
    func unregisterAllByTransport() async {
        let routes = SubscriptionTransportRoutes()
        let pair = InProcessTransportPair.connected()
        let other = InProcessTransportPair.connected()
        defer {
            Task {
                await pair.agentEnd.close()
                await other.agentEnd.close()
            }
        }

        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        await routes.register(idA, transport: pair.agentEnd)
        await routes.register(idB, transport: pair.agentEnd)
        await routes.register(idC, transport: other.agentEnd)

        await routes.unregisterAll(transport: pair.agentEnd)

        #expect(await routes.hasMapping(for: idA) == false)
        #expect(await routes.hasMapping(for: idB) == false)
        #expect(await routes.hasMapping(for: idC), "other transport's mapping must survive")
        #expect(await routes.count() == 1)
    }
}
