// SprigctlAgentServingTests.swift
//
// The IPC-serving end-to-end tests (two real processes: the spawned
// `sprigctl agent` serving, this test process as the transport
// client). Split from SprigctlAgentTests.swift for the file-length
// cap. UDS on Linux/macOS (ADR 0076), named pipe on Windows
// (ADR 0067) — same protocol, same framing.

import Foundation
import GitCore
import IPCSchema
import Testing
import TransportKit

extension SprigctlAgentTests {
    #if os(Linux) || os(macOS)
        @Test("agent --socket serves AgentEvent envelopes to a second process end-to-end")
        func socketServesSubscriber() async throws {
            // The M2 milestone moment: the agent in ONE process, this
            // test as the IPC client in another, talking the real
            // protocol — connect → subscribe → ack → file change →
            // badgeChanged envelope.
            let repo = try Sprigctl.mkRepo("agent-socket")
            defer { try? FileManager.default.removeItem(at: repo) }
            try await Sprigctl.initRepo(at: repo)
            try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
            try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
            try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)
            let socketPath = "/tmp/sprig-agent-e2e-\(UUID().uuidString.prefix(8)).sock"

            // Agent process runs concurrently; the duration is a safety
            // cap, not a tight deadline. 25 s, not 8: on a loaded
            // hosted macos-15 runner the agent's own process spawn +
            // UDS-server bring-up can eat several seconds before the
            // client's connect-retry even succeeds, leaving too little
            // of an 8 s life for the subscribe → dirty → poll →
            // badgeChanged round-trip — the agent shut down first and
            // the subscriber saw `subscriptionEnded(agent_shutdown)`
            // instead (flaked macos-15 on PR #156 CI). The agent still
            // exits on its own; a healthy run finishes the handshake in
            // a few seconds regardless of the cap.
            let agentRun = Task {
                try await Sprigctl.run([
                    "agent",
                    "--polling", "--polling-interval", "0.2",
                    "--duration", "25",
                    "--socket", socketPath,
                    repo.path
                ])
            }

            // Connect with retry while the agent boots.
            let client = try await connectWithRetry(path: socketPath)

            // Subscribe to the repo root and await the ack.
            let request = Envelope(message: ClientRequest.subscribe(
                SubscribePayload(roots: [repo.path])
            ))
            try await client.send(EnvelopeCodec.encode(request))
            var inbox = client.messages().makeAsyncIterator()
            let ackData = try #require(await inbox.next(), "expected a subscribe ack")
            let ack = try EnvelopeCodec.decode(AgentResponse.self, from: ackData)
            guard case .subscribeAck = ack.message else {
                Issue.record("expected subscribeAck, got \(ack.message)")
                return
            }

            // Dirty the repo; the polling watcher turns it into a
            // badgeChanged envelope routed to OUR subscription.
            try Sprigctl.write("changed\n", to: repo.appendingPathComponent("a.txt"))
            let eventData = try #require(await inbox.next(), "expected a badge event")
            let event = try EnvelopeCodec.decode(AgentEvent.self, from: eventData)
            guard case .badgeChanged = event.message else {
                Issue.record("expected badgeChanged, got \(event.message)")
                return
            }

            await client.close()
            let out = try await agentRun.value
            #expect(out.exitCode == 0)
            #expect(out.stderr.contains("# agent: serving at \(socketPath)"))
        }

        private func connectWithRetry(path: String) async throws -> UnixSocketTransport {
            for _ in 0 ..< 50 {
                if let transport = try? UnixSocketTransport.connect(path: path) {
                    return transport
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw TransportError.sendFailed(reason: "agent socket never came up at \(path)")
        }
    #endif

    #if os(Windows)
        @Test("agent --pipe serves AgentEvent envelopes to a second process end-to-end")
        func pipeServesSubscriber() async throws {
            // The Windows face of the UDS e2e: same protocol, named
            // pipe transport — connect → subscribe → ack → file
            // change → badgeChanged envelope.
            let repo = try Sprigctl.mkRepo("agent-pipe")
            defer { try? FileManager.default.removeItem(at: repo) }
            try await Sprigctl.initRepo(at: repo)
            try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
            try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
            try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)
            let pipeName = "sprig-agent-e2e-\(UUID().uuidString.prefix(8))"

            // Generous duration: quirk-C process-spawn + filesystem
            // latency on the Windows VM. The agent exits on its own.
            let agentRun = Task {
                try await Sprigctl.run([
                    "agent",
                    "--polling", "--polling-interval", "0.2",
                    "--duration", "15",
                    "--pipe", pipeName,
                    repo.path
                ])
            }

            let client = try await connectPipeWithRetry(name: pipeName)

            let request = Envelope(message: ClientRequest.subscribe(
                SubscribePayload(roots: [repo.path])
            ))
            try await client.send(EnvelopeCodec.encode(request))
            var inbox = client.messages().makeAsyncIterator()
            let ackData = try #require(await inbox.next(), "expected a subscribe ack")
            let ack = try EnvelopeCodec.decode(AgentResponse.self, from: ackData)
            guard case .subscribeAck = ack.message else {
                Issue.record("expected subscribeAck, got \(ack.message)")
                return
            }

            try Sprigctl.write("changed\n", to: repo.appendingPathComponent("a.txt"))
            let eventData = try #require(await inbox.next(), "expected a badge event")
            let event = try EnvelopeCodec.decode(AgentEvent.self, from: eventData)
            guard case .badgeChanged = event.message else {
                Issue.record("expected badgeChanged, got \(event.message)")
                return
            }

            await client.close()
            let out = try await agentRun.value
            #expect(out.exitCode == 0)
            #expect(out.stderr.contains("# agent: serving at \(pipeName)"))
        }

        private func connectPipeWithRetry(name: String) async throws -> NamedPipeTransport {
            // 15 s budget: agent process spawn alone can take several
            // seconds on the loaded VM.
            for _ in 0 ..< 75 {
                if let transport = try? await NamedPipeTransport.client(pipeName: name) {
                    return transport
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw TransportError.sendFailed(reason: "agent pipe never came up at \(name)")
        }
    #endif
}
