import Foundation
import Testing
@testable import TransportKit

@Suite("InProcessTransport — round-trip + lifecycle")
struct InProcessTransportTests {
    // MARK: round-trip

    @Test("client → agent: a single message arrives on the agent's messages stream")
    func clientToAgentSingleMessage() async throws {
        let pair = InProcessTransportPair.connected()
        let payload = Data("hello".utf8)

        // Subscribe before sending so we don't miss the message.
        async let received: Data? = await {
            for await msg in pair.agentEnd.messages() {
                return msg
            }
            return nil
        }()

        try await pair.clientEnd.send(payload)
        await pair.clientEnd.close()

        let got = await received
        #expect(got == payload)
    }

    @Test("agent → client: replies flow through the same channel")
    func agentToClientReplies() async throws {
        let pair = InProcessTransportPair.connected()
        let request = Data("query".utf8)
        let reply = Data("answer".utf8)

        // Set up an "agent" task that echoes a transformed reply.
        let agentTask = Task {
            for await msg in pair.agentEnd.messages() where msg == request {
                try? await pair.agentEnd.send(reply)
                break
            }
        }

        // Client side: send + read reply.
        try await pair.clientEnd.send(request)
        var clientReceived: Data?
        for await msg in pair.clientEnd.messages() {
            clientReceived = msg
            break
        }

        await agentTask.value
        await pair.clientEnd.close()
        #expect(clientReceived == reply)
    }

    @Test("multiple messages preserve send order")
    func ordering() async throws {
        let pair = InProcessTransportPair.connected()
        let messages = [
            Data("one".utf8),
            Data("two".utf8),
            Data("three".utf8),
            Data("four".utf8)
        ]

        async let received: [Data] = await {
            var collected: [Data] = []
            for await msg in pair.agentEnd.messages() {
                collected.append(msg)
                if collected.count == messages.count { break }
            }
            return collected
        }()

        for msg in messages {
            try await pair.clientEnd.send(msg)
        }

        let got = await received
        #expect(got == messages)
        await pair.clientEnd.close()
    }

    // MARK: bidirectional

    @Test("bidirectional traffic doesn't cross-contaminate (client→agent vs agent→client)")
    func bidirectionalIsolation() async throws {
        let pair = InProcessTransportPair.connected()
        let c2a = Data("client-to-agent".utf8)
        let a2c = Data("agent-to-client".utf8)

        async let agentReceived: Data? = await {
            for await msg in pair.agentEnd.messages() {
                return msg
            }
            return nil
        }()
        async let clientReceived: Data? = await {
            for await msg in pair.clientEnd.messages() {
                return msg
            }
            return nil
        }()

        try await pair.clientEnd.send(c2a)
        try await pair.agentEnd.send(a2c)

        let gotAgent = await agentReceived
        let gotClient = await clientReceived
        #expect(gotAgent == c2a, "agent should receive the client's message, not its own send")
        #expect(gotClient == a2c, "client should receive the agent's reply, not its own send")
        await pair.clientEnd.close()
    }

    // MARK: close lifecycle

    @Test("close() finishes both messages() streams (client closes)")
    func clientCloseFinishesAgentStream() async throws {
        let pair = InProcessTransportPair.connected()
        async let agentMessageCount: Int = await {
            var count = 0
            for await _ in pair.agentEnd.messages() {
                count += 1
            }
            return count
        }()

        try await pair.clientEnd.send(Data("first".utf8))
        try await pair.clientEnd.send(Data("second".utf8))
        await pair.clientEnd.close()

        let count = await agentMessageCount
        #expect(count == 2)
    }

    @Test("close() is idempotent — calling twice is safe")
    func closeIdempotent() async {
        let pair = InProcessTransportPair.connected()
        await pair.clientEnd.close()
        await pair.clientEnd.close() // should not crash
    }

    @Test("send after close throws TransportError.peerClosed")
    func sendAfterCloseThrows() async {
        let pair = InProcessTransportPair.connected()
        await pair.clientEnd.close()

        do {
            try await pair.clientEnd.send(Data("late".utf8))
            Issue.record("expected send to throw after close")
        } catch let error as TransportError {
            // Both `closed` (we closed) and `peerClosed` (peer
            // observed our close, finished its end first) are
            // semantically valid here. In-process intentionally
            // collapses the distinction; documented in
            // InProcessTransport's send() comment.
            #expect(error == .peerClosed || error == .closed)
        } catch {
            Issue.record("expected TransportError, got \(error)")
        }
    }

    @Test("send after peer's close throws — peer-side lifecycle propagates")
    func sendAfterPeerCloseThrows() async {
        let pair = InProcessTransportPair.connected()
        // Agent closes its end. Client's subsequent send should fail.
        await pair.agentEnd.close()

        do {
            try await pair.clientEnd.send(Data("hello".utf8))
            Issue.record("expected send to throw after peer close")
        } catch let error as TransportError {
            #expect(error == .peerClosed)
        } catch {
            Issue.record("expected TransportError.peerClosed, got \(error)")
        }
    }

    @Test("messages() finishes naturally when peer closes")
    func messagesFinishesOnPeerClose() async {
        let pair = InProcessTransportPair.connected()
        async let messageCount: Int = await {
            var count = 0
            for await _ in pair.clientEnd.messages() {
                count += 1
            }
            return count
        }()

        // Agent closes immediately, sending nothing.
        await pair.agentEnd.close()

        let count = await messageCount
        #expect(count == 0)
    }

    // MARK: empty payload

    @Test("zero-byte payload round-trips (no special-casing)")
    func emptyPayloadRoundTrip() async throws {
        let pair = InProcessTransportPair.connected()
        async let received: Data? = await {
            for await msg in pair.agentEnd.messages() {
                return msg
            }
            return nil
        }()

        try await pair.clientEnd.send(Data())
        await pair.clientEnd.close()

        let got = await received
        #expect(got == Data())
    }
}
