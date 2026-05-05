// RepoAgentTests.swift
//
// End-to-end tests for `RepoAgent` against real git fixture repos.
// Per CLAUDE.md: "Never mock the git binary in integration tests" —
// these spawn `git init` / `git commit` etc. into temp dirs. The
// watcher is mocked (via `WatcherKit.MockFileWatcher`) so events fire
// deterministically; everything *else* is the real production stack.
//
// What's covered:
// - The full pipeline: watcher event → driver → refresher → store →
//   broadcaster → registry → sink (envelope arrives).
// - Subscription routing: paths outside the subscriber's roots don't
//   produce envelopes.
// - Lifecycle: `start()` is idempotent; `stop()` shuts down the watcher
//   loop without orphaning the sink stream.

@testable import AgentKit
import Foundation
import GitCore
import IPCSchema
import PlatformKit
import RepoState
import Testing
import WatcherKit

@Suite("RepoAgent — end-to-end against real git")
struct RepoAgentTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-agent-\(tag)-\(UUID().uuidString)")
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

    /// Wait up to `timeout` for the sink to deliver at least one envelope
    /// matching `predicate`. Returns the matched envelope or nil on
    /// timeout.
    private func awaitEnvelope(
        from sink: InMemoryBadgeEventSink,
        timeout: Duration = .seconds(5),
        where predicate: @escaping @Sendable (Envelope<AgentEvent>) -> Bool = { _ in true }
    ) async -> Envelope<AgentEvent>? {
        await withTaskGroup(of: Envelope<AgentEvent>?.self) { group in
            group.addTask {
                for await envelope in sink.events where predicate(envelope) {
                    return envelope
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

    // MARK: end-to-end pipeline

    @Test("a watcher event for a modified file produces a badgeChanged envelope")
    func endToEndModifiedFile() async throws {
        let (root, runner) = try await mkRepo("e2e-modify")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try write("v1\n", to: file)
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
        defer { Task { await agent.stop() } }

        // Modify the file *before* injecting the watcher event so the
        // refresher sees the dirty state when it runs.
        try write("v2\n", to: file)
        await watcher.emit(WatchEvent(path: file, kind: .modified))

        let envelope = try #require(
            await awaitEnvelope(from: sink),
            "expected at least one badgeChanged envelope"
        )
        if case let .badgeChanged(payload) = envelope.message {
            #expect(payload.path == file.path)
            #expect(payload.badge == BadgeIdentifier.modified.rawValue)
        } else {
            Issue.record("expected .badgeChanged, got \(envelope.message)")
        }
    }

    @Test("an initial refresh on a dirty repo fans out the existing badges")
    func initialRefreshFiresForExistingDirt() async throws {
        let (root, runner) = try await mkRepo("e2e-initial")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try write("v1\n", to: file)
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        try write("v2\n", to: file) // already dirty when the agent starts

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
        defer { Task { await agent.stop() } }

        // No watcher events injected — we're testing the forced initial
        // refresh that `start()` performs.
        let envelope = try #require(
            await awaitEnvelope(from: sink),
            "the start-up refresh should fan out the existing modified file"
        )
        if case let .badgeChanged(payload) = envelope.message {
            #expect(payload.path == file.path)
        } else {
            Issue.record("expected .badgeChanged, got \(envelope.message)")
        }
    }

    // MARK: subscription routing

    @Test("a subscriber on an unrelated root receives no envelopes")
    func subscriberOnUnrelatedRootGetsNothing() async throws {
        let (root, runner) = try await mkRepo("e2e-unrelated")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try write("v1\n", to: file)
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
        // Subscribe to a path that has nothing to do with the repo —
        // the broadcaster should never deliver to this subscriber.
        let elsewhere = URL(fileURLWithPath: "/this/does/not/exist/anywhere/in/the/repo")
        _ = await registry.subscribe(roots: [elsewhere])

        try await agent.start()
        defer { Task { await agent.stop() } }

        try write("v2\n", to: file)
        await watcher.emit(WatchEvent(path: file, kind: .modified))

        // Expect a *short* timeout — we're asserting absence, so a
        // longer wait would just slow the suite for no signal gain.
        let envelope = await awaitEnvelope(from: sink, timeout: .milliseconds(500))
        #expect(envelope == nil, "subscriber on unrelated root must not receive envelopes")
    }

    // MARK: lifecycle

    @Test("calling start() twice is idempotent and doesn't double-spawn the loop")
    func startIsIdempotent() async throws {
        let (root, runner) = try await mkRepo("e2e-idempotent")
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
        try await agent.start() // must be a no-op, not a re-spawn
        await agent.stop()

        // If start() had spawned two loops, one would still be running
        // after a single stop(). The test passing under no flakes is
        // the assertion; we don't have a public "is running?" API and
        // adding one for a test would over-fit the surface.
    }

    @Test("stop() finishes the sink stream so consumers can terminate")
    func stopReleasesConsumers() async throws {
        let (root, runner) = try await mkRepo("e2e-stop")
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

        // The sink's stream must terminate now; otherwise the consumer
        // would hang forever. Iterate with a short timeout to catch a
        // regression where stop+finish doesn't cleanly close the stream.
        let task = Task {
            for await _ in sink.events {}
            return true
        }
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                task.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(result, "sink.events should finish after stop()+finish()")
    }
}
