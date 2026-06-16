// RepoAgentAutoBackupTests.swift
//
// ADR 0075 agent wiring: an agent constructed with AutoBackupStartup
// backs up a dirty tree on its tick and TTL-prunes. The engine's
// behavior is covered by SafetyKit's WorktreeBackupTests; here we
// prove the glue only.

@testable import AgentKit
import Foundation
import GitCore
import RepoState
import SafetyKit
import Testing
import WatcherKit

@Suite("RepoAgent — ADR 0075 auto-backup wiring")
struct RepoAgentAutoBackupTests {
    @Test("agent with AutoBackupStartup backs up a dirty tree on its tick")
    func agentBacksUpDirtyTree() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-agent-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        try Data("uncommitted work\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: dir)
        let agent = RepoAgent(
            repoRoot: dir,
            gitDir: gitDir,
            runner: runner,
            watcher: MockFileWatcher(),
            registry: SubscriptionRegistry(),
            sink: InMemoryBadgeEventSink(),
            tickInterval: .milliseconds(20),
            snapshotPolicy: .disabled,
            autoBackup: AutoBackupStartup(
                configuration: AutoSyncConfiguration(
                    interval: .milliseconds(50),
                    jitterFraction: 0,
                    fireOnStart: true
                )
            )
        )
        try await agent.start()

        // Await the backup ref within a generous Windows-friendly budget.
        // 60 s, not 30 s: this is a live background loop (the agent's
        // 50 ms backup tick spawns git per attempt) asserted under the
        // full parallel suite on a 2-core hosted Windows runner. The
        // tick *is* firing — it's CPU/process-spawn contention that can
        // starve it past a tighter budget (VM-ENV-1 environmental flake
        // class). The wait only bounds failure; a healthy run breaks the
        // instant the ref appears.
        let backup = WorktreeBackup(runner: runner)
        let deadline = Date().addingTimeInterval(60)
        var entries: [WorktreeBackupEntry] = []
        while Date() < deadline {
            entries = await (try? backup.backups()) ?? []
            if !entries.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await agent.stop()

        #expect(!entries.isEmpty, "the agent's backup tick should have created a ref")
        if let entry = entries.first {
            let content = try await runner.run(["show", "\(entry.ref.refName):a.txt"]).stdoutString
            #expect(content == "uncommitted work\n")
        }
    }
}
