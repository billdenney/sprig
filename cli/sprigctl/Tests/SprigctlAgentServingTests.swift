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

            // `--exit-on-last-client` is the de-flake (it replaced three
            // rounds of bumping `--duration` — 8 s flaked on PR #156, 25 s
            // on PR #162, 60 s on BOTH macos-14 and macos-15 in one run on
            // 2026-06-19). The agent's lifetime now tracks THIS client:
            // when `client.close()` below disconnects, the serving layer's
            // last-client signal stops the agent and it exits 0 within a
            // few seconds — `await agentRun.value` no longer waits out a
            // fixed cap. So `--duration` is a pure safety ceiling that the
            // dirty → poll → badgeChanged round-trip never races: on a
            // starved hosted runner the round-trip can take tens of
            // seconds, but the agent only shuts down on disconnect (not
            // the timer), so it can never beat the badge to the wire.
            let agentRun = Task {
                try await Sprigctl.run([
                    "agent",
                    "--polling", "--polling-interval", "0.2",
                    "--exit-on-last-client",
                    "--duration", "300",
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

            // `--exit-on-last-client`: the agent's lifetime tracks THIS
            // client, so `client.close()` below stops it and it exits 0
            // promptly — the same de-flake the UDS variant uses. With the
            // shutdown driven by disconnect rather than the timer, the
            // quirk-C process-spawn + filesystem latency on the Windows VM
            // can no longer let the cap expire before the badge round-trip
            // completes; `--duration` is a pure safety ceiling.
            let agentRun = Task {
                try await Sprigctl.run([
                    "agent",
                    "--polling", "--polling-interval", "0.2",
                    "--exit-on-last-client",
                    "--duration", "120",
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
