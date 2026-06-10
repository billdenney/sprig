// TeeBadgeEventSinkTests.swift
//
// The tee's two contracts: every child sink sees every envelope, and
// one broken child neither starves the others nor hides its error
// (first failure rethrown after all children were attempted).

@testable import AgentKit
import Foundation
import IPCSchema
import RepoState
import Testing

private struct TeeTestBoom: Error {}

private struct FailingSink: BadgeEventSink {
    func emit(_: Envelope<AgentEvent>) async throws {
        throw TeeTestBoom()
    }
}

@Suite("TeeBadgeEventSink — fan-out + failure isolation")
struct TeeBadgeEventSinkTests {
    private func makeEnvelope() -> Envelope<AgentEvent> {
        Envelope(message: AgentEvent.subscriptionEnded(
            SubscriptionEndedPayload(subscriptionId: UUID(), reason: "internal")
        ))
    }

    @Test("every child sink receives every envelope, in order")
    func fanOut() async throws {
        let first = InMemoryBadgeEventSink()
        let second = InMemoryBadgeEventSink()
        let tee = TeeBadgeEventSink([first, second])

        let one = makeEnvelope()
        let two = makeEnvelope()
        try await tee.emit(one)
        try await tee.emit(two)
        first.finish()
        second.finish()

        var firstInbox = first.events.makeAsyncIterator()
        #expect(await firstInbox.next() == one)
        #expect(await firstInbox.next() == two)
        var secondInbox = second.events.makeAsyncIterator()
        #expect(await secondInbox.next() == one)
        #expect(await secondInbox.next() == two)
    }

    @Test("a failing child doesn't starve the others; its error is rethrown afterwards")
    func failureIsolation() async throws {
        let healthy = InMemoryBadgeEventSink()
        let tee = TeeBadgeEventSink([FailingSink(), healthy])

        let envelope = makeEnvelope()
        await #expect(throws: TeeTestBoom.self) {
            try await tee.emit(envelope)
        }
        healthy.finish()
        var inbox = healthy.events.makeAsyncIterator()
        #expect(await inbox.next() == envelope, "the healthy sink still got the envelope")
    }
}
