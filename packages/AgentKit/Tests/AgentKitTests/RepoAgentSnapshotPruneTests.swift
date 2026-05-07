// RepoAgentSnapshotPruneTests.swift
//
// Tests `RepoAgent`'s startup TTL prune of `refs/sprig/snapshots/...`
// per ADR 0033. Spawns real git fixtures and writes snapshot refs via
// `SnapshotRefName` so the tests exercise the same wire format the
// production pipeline produces.

@testable import AgentKit
import Foundation
import GitCore
import RepoState
import SafetyKit
import Testing
import WatcherKit

@Suite("RepoAgent — startup snapshot prune (ADR 0033)")
struct RepoAgentSnapshotPruneTests {
    // MARK: - Fixture helpers

    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-snap-prune-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: tmp.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (tmp, runner)
    }

    /// Write a `refs/sprig/snapshots/<ts>/<op>` ref via raw
    /// `git update-ref`. Mirrors `SnapshotWriter` but doesn't depend
    /// on its public surface.
    @discardableResult
    private func writeSnapshot(
        at timestamp: Date,
        op: String,
        runner: Runner
    ) async throws -> SnapshotRefName {
        guard let name = SnapshotRefName(timestamp: timestamp, op: op) else {
            throw FixtureError.invalidRefName
        }
        _ = try await runner.run(["update-ref", name.refName, "HEAD"])
        return name
    }

    private func makeAgent(
        root: URL,
        runner: Runner,
        snapshotPolicy: SnapshotPolicy
    ) async throws -> RepoAgent {
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let registry = SubscriptionRegistry()
        let sink = InMemoryBadgeEventSink()
        return RepoAgent(
            repoRoot: root,
            gitDir: gitDir,
            runner: runner,
            watcher: MockFileWatcher(),
            registry: registry,
            sink: sink,
            tickInterval: .milliseconds(20),
            snapshotPolicy: snapshotPolicy
        )
    }

    /// Count snapshot refs in the repo via direct `git for-each-ref`,
    /// independent of `SnapshotIndex` — used to verify the agent's
    /// prune actually deleted refs on disk.
    private func liveSnapshotCount(in runner: Runner) async throws -> Int {
        let output = try await runner.run([
            "for-each-ref",
            "--format=%(refname)",
            SnapshotRefName.prefix
        ])
        return output.stdoutString.split(separator: "\n").count
    }

    // MARK: - Default policy (prune on startup, 30-day TTL)

    @Test("default policy: no snapshots → prune count stays 0, prune time set")
    func defaultPolicyEmptyRepo() async throws {
        let (root, runner) = try await mkRepo("default-empty")
        defer { try? FileManager.default.removeItem(at: root) }

        let agent = try await makeAgent(root: root, runner: runner, snapshotPolicy: .default)
        try await agent.start()
        defer { Task { await agent.stop() } }

        #expect(await agent.lastSnapshotPruneCount() == 0)
        // The prune ran successfully (just had nothing to delete);
        // pruneAt is set so monitoring can detect "agent ran the
        // prune step at all."
        #expect(await agent.lastSnapshotPruneAt() != nil)
    }

    @Test("default policy: 30-day-old snapshot is pruned on startup")
    func defaultPolicyPrunesOldSnapshot() async throws {
        let (root, runner) = try await mkRepo("default-old")
        defer { try? FileManager.default.removeItem(at: root) }
        // 60 days old — well past the 30-day default TTL.
        let oldTimestamp = Date().addingTimeInterval(-60 * 86400)
        try await writeSnapshot(at: oldTimestamp, op: SnapshotRefName.opMerge, runner: runner)
        #expect(try await liveSnapshotCount(in: runner) == 1)

        let agent = try await makeAgent(root: root, runner: runner, snapshotPolicy: .default)
        try await agent.start()
        defer { Task { await agent.stop() } }

        #expect(await agent.lastSnapshotPruneCount() == 1)
        #expect(try await liveSnapshotCount(in: runner) == 0, "the old snapshot should be gone")
    }

    @Test("default policy: recent snapshot (1 day old) is kept")
    func defaultPolicyKeepsRecent() async throws {
        let (root, runner) = try await mkRepo("default-recent")
        defer { try? FileManager.default.removeItem(at: root) }
        // 1 day old — well within the 30-day TTL.
        let recent = Date().addingTimeInterval(-86400)
        try await writeSnapshot(at: recent, op: SnapshotRefName.opRebase, runner: runner)

        let agent = try await makeAgent(root: root, runner: runner, snapshotPolicy: .default)
        try await agent.start()
        defer { Task { await agent.stop() } }

        #expect(await agent.lastSnapshotPruneCount() == 0)
        #expect(try await liveSnapshotCount(in: runner) == 1, "recent snapshot should survive")
    }

    @Test("default policy: mixed old + recent — only old gets pruned")
    func defaultPolicyMixed() async throws {
        let (root, runner) = try await mkRepo("default-mixed")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDate = Date().addingTimeInterval(-90 * 86400)
        let recentDate = Date().addingTimeInterval(-3600) // 1 hour
        try await writeSnapshot(at: oldDate, op: SnapshotRefName.opMerge, runner: runner)
        try await writeSnapshot(at: recentDate, op: SnapshotRefName.opForcePush, runner: runner)

        let agent = try await makeAgent(root: root, runner: runner, snapshotPolicy: .default)
        try await agent.start()
        defer { Task { await agent.stop() } }

        #expect(await agent.lastSnapshotPruneCount() == 1)
        #expect(try await liveSnapshotCount(in: runner) == 1)
    }

    // MARK: - Custom TTL

    @Test("custom TTL of 1 hour prunes anything older than 1 hour")
    func customTTL() async throws {
        let (root, runner) = try await mkRepo("custom-ttl")
        defer { try? FileManager.default.removeItem(at: root) }
        let twoHoursAgo = Date().addingTimeInterval(-2 * 3600)
        let halfHourAgo = Date().addingTimeInterval(-1800)
        try await writeSnapshot(at: twoHoursAgo, op: SnapshotRefName.opMerge, runner: runner)
        try await writeSnapshot(at: halfHourAgo, op: SnapshotRefName.opRebase, runner: runner)

        let policy = SnapshotPolicy(pruneOnStartup: true, ttl: 3600)
        let agent = try await makeAgent(root: root, runner: runner, snapshotPolicy: policy)
        try await agent.start()
        defer { Task { await agent.stop() } }

        // Only the 2-hour-old snapshot is past the 1-hour TTL.
        #expect(await agent.lastSnapshotPruneCount() == 1)
        #expect(try await liveSnapshotCount(in: runner) == 1)
    }

    // MARK: - Disabled policy

    @Test("disabled policy: snapshot index untouched, count stays 0, time stays nil")
    func disabledPolicy() async throws {
        let (root, runner) = try await mkRepo("disabled")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDate = Date().addingTimeInterval(-365 * 86400) // 1 year
        try await writeSnapshot(at: oldDate, op: SnapshotRefName.opMerge, runner: runner)

        let agent = try await makeAgent(root: root, runner: runner, snapshotPolicy: .disabled)
        try await agent.start()
        defer { Task { await agent.stop() } }

        #expect(await agent.lastSnapshotPruneCount() == 0)
        #expect(await agent.lastSnapshotPruneAt() == nil, ".disabled never sets pruneAt")
        #expect(try await liveSnapshotCount(in: runner) == 1, "ancient snapshot should survive")
    }

    // MARK: - Pre-start defaults

    @Test("before start(), prune diagnostics are at safe defaults")
    func preStartDefaults() async throws {
        let (root, runner) = try await mkRepo("pre-start")
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try await makeAgent(root: root, runner: runner, snapshotPolicy: .default)
        // No await agent.start() — read diagnostics directly.
        #expect(await agent.lastSnapshotPruneCount() == 0)
        #expect(await agent.lastSnapshotPruneAt() == nil)
    }
}

private enum FixtureError: Error {
    case invalidRefName
}
