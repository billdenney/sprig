// SprigctlSyncTests.swift
//
// `sprigctl sync` end-to-end against the built binary + real git.
// SyncOps' branch-by-branch behavior is covered in GitCore's
// SyncOpsTests; here we exercise the CLI contract: human output
// shape, --pull mutation, --json parseability, flag validation.

import Foundation
import Testing

// `.serialized`: three-repo fixtures + sprigctl binary spawns per
// test; see SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("sprigctl sync", .serialized)
struct SprigctlSyncTests {
    /// Bare origin + publisher + subscriber; one commit pushed and a
    /// second waiting un-fetched. Returns root for cleanup +
    /// subscriber as the CLI's target.
    private func makeFixture(
        _ label: String
    ) async throws -> (root: URL, subscriber: URL) {
        let root = try Sprigctl.mkRepo("sync-\(label)")
        let origin = root.appendingPathComponent("origin.git")
        try await Sprigctl.spawnGit(["init", "--bare", "-b", "main", origin.path], cwd: root)

        let publisher = root.appendingPathComponent("publisher")
        try await Sprigctl.spawnGit(["clone", origin.path, publisher.path], cwd: root)
        try await Sprigctl.initRepo(at: publisher) // re-applies identity config; init is idempotent
        try Sprigctl.write("seed\n", to: publisher.appendingPathComponent("seed.txt"))
        try await Sprigctl.spawnGit(["add", "seed.txt"], cwd: publisher)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: publisher)
        try await Sprigctl.spawnGit(["push", "origin", "main"], cwd: publisher)

        let subscriber = root.appendingPathComponent("subscriber")
        try await Sprigctl.spawnGit(["clone", origin.path, subscriber.path], cwd: root)
        try await Sprigctl.initRepo(at: subscriber)

        // Second commit the subscriber hasn't seen.
        try Sprigctl.write("incoming\n", to: publisher.appendingPathComponent("incoming.txt"))
        try await Sprigctl.spawnGit(["add", "incoming.txt"], cwd: publisher)
        try await Sprigctl.spawnGit(["commit", "-m", "incoming"], cwd: publisher)
        try await Sprigctl.spawnGit(["push", "origin", "main"], cwd: publisher)

        return (root, subscriber)
    }

    @Test("default invocation fetches and reports behind state")
    func fetchAndReport() async throws {
        let fixture = try await makeFixture("report")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let run = try await Sprigctl.run(["sync", fixture.subscriber.path])
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("main"))
        #expect(run.stdout.contains("behind origin/main by 1"))
        // No --pull: the working tree must be untouched.
        let untouched = fixture.subscriber.appendingPathComponent("incoming.txt")
        #expect(!FileManager.default.fileExists(atPath: untouched.path))
    }

    @Test("--pull fast-forwards the clean checked-out branch")
    func pullFastForwards() async throws {
        let fixture = try await makeFixture("pull")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let run = try await Sprigctl.run(["sync", "--pull", fixture.subscriber.path])
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("fast-forwarded"))
        #expect(run.stdout.contains("up to date with origin/main"))
        let landed = fixture.subscriber.appendingPathComponent("incoming.txt")
        #expect(FileManager.default.fileExists(atPath: landed.path))
    }

    @Test("--pull on a dirty worktree reports the skip and leaves the tree alone")
    func pullSkipsDirty() async throws {
        let fixture = try await makeFixture("dirty")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Sprigctl.write(
            "local edit\n",
            to: fixture.subscriber.appendingPathComponent("seed.txt")
        )

        let run = try await Sprigctl.run(["sync", "--pull", fixture.subscriber.path])
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("skipped: uncommitted changes"))
        let untouched = fixture.subscriber.appendingPathComponent("incoming.txt")
        #expect(!FileManager.default.fileExists(atPath: untouched.path))
    }

    @Test("--json emits parseable JSON with the documented shape")
    func jsonShape() async throws {
        let fixture = try await makeFixture("json")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let run = try await Sprigctl.run(["sync", "--pull", "--json", fixture.subscriber.path])
        #expect(run.exitCode == 0)
        let object = try JSONSerialization.jsonObject(with: Data(run.stdout.utf8))
        let report = try #require(object as? [String: Any])
        #expect(report["fetched"] as? Bool == true)
        #expect(report["pullRequested"] as? Bool == true)
        #expect(report["pullSkippedMidOperation"] as? Bool == false)
        let branches = try #require(report["branches"] as? [[String: Any]])
        let main = try #require(branches.first { $0["name"] as? String == "main" })
        #expect(main["pullOutcome"] as? String == "fast-forwarded")
        #expect(main["behind"] as? Int == 0)
        #expect(main["current"] as? Bool == true)
    }

    @Test("--autostash without --pull errors with a helpful message")
    func autostashRequiresPull() async throws {
        let fixture = try await makeFixture("flagcheck")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let run = try await Sprigctl.run(["sync", "--autostash", fixture.subscriber.path])
        #expect(run.exitCode != 0)
        #expect(run.stderr.contains("--autostash only makes sense with --pull"))
    }
}
