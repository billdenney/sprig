// RepoAgentDiagnosticsTests.swift
//
// Coverage for `RepoAgent`'s diagnostic accessors —
// `refreshAttempts()`, `lastOutcome()`, `firstDeferralAt()`. Each
// delegates to the underlying `RepoRefreshDriver` once `start()` has
// constructed one; before that, they return safe defaults.
//
// Spawns real git per CLAUDE.md ("Never mock the git binary in
// integration tests"). The watcher is mocked via
// `WatcherKit.MockFileWatcher` so refresh ticks are deterministic.

@testable import AgentKit
import Foundation
import GitCore
import IPCSchema
import PlatformKit
import RepoState
import Testing
import WatcherKit

@Suite("RepoAgent diagnostics — refreshAttempts / lastOutcome / firstDeferralAt")
struct RepoAgentDiagnosticsTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-diag-\(tag)-\(UUID().uuidString)")
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

    private func makeAgent(
        root: URL,
        runner: Runner,
        watcher: any FileWatcher
    ) async throws -> RepoAgent {
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let registry = SubscriptionRegistry()
        let sink = InMemoryBadgeEventSink()
        return RepoAgent(
            repoRoot: root,
            gitDir: gitDir,
            runner: runner,
            watcher: watcher,
            registry: registry,
            sink: sink,
            tickInterval: .milliseconds(20)
        )
    }

    // MARK: pre-start defaults

    @Test("before start(), all diagnostics return safe defaults (0 / nil / nil)")
    func defaultsBeforeStart() async throws {
        let (root, runner) = try await mkRepo("pre-start")
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try await makeAgent(
            root: root,
            runner: runner,
            watcher: MockFileWatcher()
        )

        #expect(await agent.refreshAttempts() == 0)
        #expect(await agent.lastOutcome() == nil)
        #expect(await agent.firstDeferralAt() == nil)
    }

    // MARK: post-start (after the forced initial refresh)

    @Test("after start(), refreshAttempts == 1 (forced initial refresh) and lastOutcome is .applied")
    func initialRefreshIncrementsAttempts() async throws {
        let (root, runner) = try await mkRepo("post-start")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let agent = try await makeAgent(
            root: root,
            runner: runner,
            watcher: MockFileWatcher()
        )
        try await agent.start()
        defer { Task { await agent.stop() } }

        #expect(await agent.refreshAttempts() == 1, "the forced initial refresh counts")
        if case .applied = await agent.lastOutcome() {
            // expected
        } else {
            await Issue.record("expected .applied outcome on a clean repo, got \(String(describing: agent.lastOutcome()))")
        }
        #expect(await agent.firstDeferralAt() == nil, "no deferral on a clean refresh")
    }

    // MARK: deferral path

    @Test("when index.lock is present at start, firstDeferralAt is set on the forced initial refresh")
    func firstDeferralAtSetOnLockPresent() async throws {
        let (root, runner) = try await mkRepo("defer")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        // Plant index.lock so the driver defers the forced initial refresh.
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let lock = gitDir.appendingPathComponent("index.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }

        let agent = try await makeAgent(
            root: root,
            runner: runner,
            watcher: MockFileWatcher()
        )
        let beforeStart = Date()
        try await agent.start()
        let afterStart = Date()
        defer { Task { await agent.stop() } }

        let stamp = try #require(
            await agent.firstDeferralAt(),
            "firstDeferralAt must be set after a deferred forced refresh"
        )
        #expect(stamp >= beforeStart && stamp <= afterStart)
        if case .deferred = await agent.lastOutcome() {
            // expected
        } else {
            await Issue.record("expected .deferred outcome with index.lock present, got \(String(describing: agent.lastOutcome()))")
        }
    }

    @Test("firstDeferralAt clears once a refresh succeeds")
    func firstDeferralAtClearsOnSuccess() async throws {
        let (root, runner) = try await mkRepo("clear")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let lock = gitDir.appendingPathComponent("index.lock")
        try Data().write(to: lock)

        let watcher = MockFileWatcher()
        let agent = try await makeAgent(root: root, runner: runner, watcher: watcher)
        try await agent.start()
        defer { Task { await agent.stop() } }
        #expect(await agent.firstDeferralAt() != nil, "deferred at start time")

        // Clear the lock; emit a watcher event so a refresh fires; the
        // driver should observe success and clear firstDeferralAt.
        try FileManager.default.removeItem(at: lock)
        await watcher.emit(WatchEvent(
            path: root.appendingPathComponent("a.txt"),
            kind: .modified
        ))

        // Poll briefly — the tick task picks up events on its own
        // schedule. Bounded so a regression doesn't hang the suite.
        var cleared = false
        for _ in 0 ..< 50 {
            if await agent.firstDeferralAt() == nil {
                cleared = true
                break
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        #expect(cleared, "firstDeferralAt should clear within 2 seconds of the lock disappearing")
    }
}
