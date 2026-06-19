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

            // Agent process runs concurrently. `--duration` is a pure
            // safety cap (so a wedged test can't leak the child), NOT the
            // normal stop signal: the test CANCELS `agentRun` the instant
            // the badge round-trip succeeds (see below), which terminates
            // the child immediately. That decouples the agent's lifetime
            // from a wall-clock timer and kills the flake where a starved
            // hosted runner let the cap fire before the handshake
            // finished — the subscriber then saw
            // `subscriptionEnded(agent_shutdown)` instead of the badge
            // (flaked at 8 s on PR #156, 25 s on PR #162, and even 60 s on
            // PR #176 when the loaded runner stretched the whole test past
            // 60 s). The cap is large because a healthy run never reaches
            // it — the cancel always stops the agent first.
            let agentRun = Task {
                try await Sprigctl.run([
                    "agent",
                    "--polling", "--polling-interval", "0.2",
                    "--duration", "180",
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
            // Badge round-trip done — stop the agent NOW (cancel →
            // terminate) instead of waiting out the safety-cap duration.
            agentRun.cancel()
            let out = try await agentRun.value
            // We terminated it, so the exit code is the signal, not 0;
            // the serving banner (printed at startup) proves it served.
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

            // `--duration` is a pure safety cap; the test cancels
            // `agentRun` the moment the badge arrives (terminating the
            // child), so the agent's lifetime is bounded by the handshake
            // rather than a wall-clock timer that can race quirk-C
            // process-spawn + filesystem latency on a loaded Windows VM.
            let agentRun = Task {
                try await Sprigctl.run([
                    "agent",
                    "--polling", "--polling-interval", "0.2",
                    "--duration", "180",
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
            // Badge round-trip done — stop the agent NOW (cancel →
            // terminate) instead of waiting out the safety-cap duration.
            agentRun.cancel()
            let out = try await agentRun.value
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
