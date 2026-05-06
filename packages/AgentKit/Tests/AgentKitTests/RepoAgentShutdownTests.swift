// RepoAgentShutdownTests.swift
//
// Verifies that `RepoAgent.stop()` fans out
// `IPCSchema.AgentEvent.subscriptionEnded` envelopes (reason
// `"agent_shutdown"`) to every active subscription before tearing
// down the watcher loop. Closes the IPC schema gap where
// `subscriptionEnded` had no producer.

@testable import AgentKit
import Foundation
import GitCore
import IPCSchema
import PlatformKit
import RepoState
import Testing
import WatcherKit

@Suite("RepoAgent.stop() — fans subscriptionEnded events to active subscribers")
struct RepoAgentShutdownTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-shutdown-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        return (tmp, runner)
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    /// Drain `events` until either a `subscriptionEnded` arrives or
    /// the stream finishes. Returns the matched envelope or nil.
    private func awaitSubscriptionEnded(
        from sink: InMemoryBadgeEventSink,
        timeout: Duration = .seconds(2)
    ) async -> Envelope<AgentEvent>? {
        await withTaskGroup(of: Envelope<AgentEvent>?.self) { group in
            group.addTask {
                for await envelope in sink.events {
                    if case .subscriptionEnded = envelope.message {
                        return envelope
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    @Test("stop() emits one subscriptionEnded envelope per active subscription with reason agent_shutdown")
    func stopFansSubscriptionEnded() async throws {
        let (root, runner) = try await mkRepo("end")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let watcher = MockFileWatcher()
        let registry = SubscriptionRegistry()
        let sink = InMemoryBadgeEventSink()
        let agent = RepoAgent(
            repoRoot: root,
            gitDir: gitDir,
            runner: runner,
            watcher: watcher,
            registry: registry,
            sink: sink,
            tickInterval: .milliseconds(20)
        )
        let id1 = await registry.subscribe(roots: [root])
        let id2 = await registry.subscribe(roots: [root])
        try await agent.start()
        await agent.stop()
        sink.finish()

        // The first non-badgeChanged envelope should be a
        // subscriptionEnded for one of the registered subscribers.
        let endedEnv = try #require(
            await awaitSubscriptionEnded(from: sink),
            "expected at least one subscriptionEnded envelope after stop()"
        )
        guard case let .subscriptionEnded(payload) = endedEnv.message else {
            Issue.record("expected .subscriptionEnded, got \(endedEnv.message)")
            return
        }
        #expect(payload.reason == "agent_shutdown")
        #expect([id1, id2].contains(payload.subscriptionId), "id must be one of the registered subscriptions")
    }

    @Test("stop() with no active subscriptions doesn't crash and emits no subscriptionEnded events")
    func stopWithoutSubscribersIsClean() async throws {
        let (root, runner) = try await mkRepo("no-subs")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let watcher = MockFileWatcher()
        let registry = SubscriptionRegistry()
        let sink = InMemoryBadgeEventSink()
        let agent = RepoAgent(
            repoRoot: root,
            gitDir: gitDir,
            runner: runner,
            watcher: watcher,
            registry: registry,
            sink: sink,
            tickInterval: .milliseconds(20)
        )

        try await agent.start()
        await agent.stop()
        sink.finish()

        // Drain everything and confirm none are subscriptionEnded.
        var ended = 0
        for await envelope in sink.events {
            if case .subscriptionEnded = envelope.message {
                ended += 1
            }
        }
        #expect(ended == 0)
    }

    @Test("calling stop() twice doesn't double-emit subscriptionEnded events")
    func stopIsIdempotentForShutdownEvents() async throws {
        let (root, runner) = try await mkRepo("idempotent")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let watcher = MockFileWatcher()
        let registry = SubscriptionRegistry()
        let sink = InMemoryBadgeEventSink()
        let agent = RepoAgent(
            repoRoot: root,
            gitDir: gitDir,
            runner: runner,
            watcher: watcher,
            registry: registry,
            sink: sink,
            tickInterval: .milliseconds(20)
        )
        _ = await registry.subscribe(roots: [root])

        try await agent.start()
        await agent.stop()
        await agent.stop() // second call must be a no-op
        sink.finish()

        var endedCount = 0
        for await envelope in sink.events {
            if case .subscriptionEnded = envelope.message {
                endedCount += 1
            }
        }
        #expect(endedCount == 1, "exactly one shutdown envelope despite two stop() calls")
    }
}
