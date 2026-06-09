// RepoAgentAutoSyncTests.swift
//
// ADR 0068 wiring: an agent constructed with `AutoSyncStartup` fetches
// in the background (and, with `fastForwardPull`, fast-forwards) —
// against real git, never mocked. The scheduler's sequencing contract
// is covered by AutoSyncSchedulerTests; SyncOps' git behavior by
// GitCore's SyncOpsTests. Here we only prove the agent glue: start()
// launches the job, stop() halts it, and the repo really moves.

@testable import AgentKit
import Foundation
import GitCore
import RepoState
import Testing
import WatcherKit

@Suite("RepoAgent — ADR 0068 auto-sync wiring")
struct RepoAgentAutoSyncTests {
    /// Bare origin + publisher + subscriber (the agent's repo), with
    /// one commit published and a second one waiting un-fetched.
    private struct Fixture {
        let root: URL
        let publisher: URL
        let subscriber: URL
    }

    private func makeFixture(_ label: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-agent-autosync-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootRunner = Runner(defaultWorkingDirectory: root)

        let origin = root.appendingPathComponent("origin.git")
        _ = try await rootRunner.run(["init", "--bare", "-b", "main", origin.path])
        let publisher = root.appendingPathComponent("publisher")
        _ = try await rootRunner.run(["clone", origin.path, publisher.path])
        try await configure(publisher)
        try await commitAndPush(named: "seed.txt", at: publisher)

        let subscriber = root.appendingPathComponent("subscriber")
        _ = try await rootRunner.run(["clone", origin.path, subscriber.path])
        try await configure(subscriber)

        // Publish a second commit the subscriber hasn't fetched.
        try await commitAndPush(named: "incoming.txt", at: publisher)
        return Fixture(root: root, publisher: publisher, subscriber: subscriber)
    }

    private func configure(_ repo: URL) async throws {
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
    }

    private func commitAndPush(named name: String, at repo: URL) async throws {
        try Data("\(name)\n".utf8).write(to: repo.appendingPathComponent(name))
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["add", name])
        _ = try await runner.run(["commit", "-m", "add \(name)"])
        _ = try await runner.run(["push", "origin", "main"])
    }

    private func makeAgent(root: URL, runner: Runner, autoSync: AutoSyncStartup) throws -> RepoAgent {
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        return RepoAgent(
            repoRoot: root,
            gitDir: gitDir,
            runner: runner,
            watcher: MockFileWatcher(),
            registry: SubscriptionRegistry(),
            sink: InMemoryBadgeEventSink(),
            tickInterval: .milliseconds(20),
            snapshotPolicy: .disabled,
            autoSync: autoSync
        )
    }

    /// Await a condition with a deadline — generous on Windows where
    /// filesystem + process latency runs seconds (cross-platform-quirks
    /// E1/E2).
    private func eventually(
        within seconds: Double = 30,
        _ condition: () async throws -> Bool
    ) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return try await condition()
    }

    @Test("agent with AutoSyncStartup fetches in the background (fire-on-start)")
    func agentFetchesOnStart() async throws {
        let fixture = try await makeFixture("fetch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)
        let agent = try makeAgent(
            root: fixture.subscriber,
            runner: runner,
            autoSync: AutoSyncStartup(
                configuration: AutoSyncConfiguration(
                    interval: .seconds(3600), // only the start-fire matters here
                    jitterFraction: 0,
                    fireOnStart: true
                ),
                fastForwardPull: false
            )
        )
        try await agent.start()
        defer { Task { await agent.stop() } }

        let sync = SyncOps(runner: runner)
        let fetched = try await eventually {
            let states = try await sync.branchSyncStates()
            return states.first { $0.name == "main" }?.behind == 1
        }
        #expect(fetched, "remote-tracking ref should advance via the agent's background fetch")

        // Fetch-only: the local branch must NOT have moved.
        let states = try await sync.branchSyncStates()
        #expect(states.first { $0.name == "main" }?.behind == 1)
        await agent.stop()
    }

    @Test("fastForwardPull: true also fast-forwards the clean checked-out branch")
    func agentFastForwards() async throws {
        let fixture = try await makeFixture("ffpull")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)
        let agent = try makeAgent(
            root: fixture.subscriber,
            runner: runner,
            autoSync: AutoSyncStartup(
                configuration: AutoSyncConfiguration(
                    interval: .seconds(3600),
                    jitterFraction: 0,
                    fireOnStart: true
                ),
                fastForwardPull: true
            )
        )
        try await agent.start()

        let landed = fixture.subscriber.appendingPathComponent("incoming.txt")
        let pulled = await eventually {
            FileManager.default.fileExists(atPath: landed.path)
        }
        #expect(pulled, "auto-pull should fast-forward main and materialize incoming.txt")

        let sync = SyncOps(runner: runner)
        let states = try await sync.branchSyncStates()
        let main = try #require(states.first { $0.name == "main" })
        #expect(main.behind == 0)
        #expect(main.ahead == 0)
        await agent.stop()
    }
}
