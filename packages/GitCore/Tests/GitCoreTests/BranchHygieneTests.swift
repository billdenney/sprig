// BranchHygieneTests.swift
//
// ADR 0073 stale-branch detection + deletion against real git.
// Fixture: bare origin + publisher (merges/deletes on the "server"
// side) + subscriber (the repo under test).

import Foundation
@testable import GitCore
import Testing

// `.serialized`: multi-repo fixtures with pushes per test; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("BranchHygiene — stale detection + deletion (real git)", .serialized)
struct BranchHygieneTests {
    private struct Fixture {
        let root: URL
        let origin: URL
        let publisher: URL
        let subscriber: URL
        let subscriberRunner: Runner
    }

    private func makeFixture(_ label: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-hygiene-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootRunner = Runner(defaultWorkingDirectory: root)

        let origin = root.appendingPathComponent("origin.git")
        _ = try await rootRunner.run(["init", "--bare", "-b", "main", origin.path])
        let publisher = root.appendingPathComponent("publisher")
        _ = try await rootRunner.run(["clone", origin.path, publisher.path])
        try await configure(publisher)
        try await commit(named: "seed.txt", at: publisher)
        _ = try await Runner(defaultWorkingDirectory: publisher).run(["push", "origin", "main"])

        let subscriber = root.appendingPathComponent("subscriber")
        _ = try await rootRunner.run(["clone", origin.path, subscriber.path])
        try await configure(subscriber)
        return Fixture(
            root: root,
            origin: origin,
            publisher: publisher,
            subscriber: subscriber,
            subscriberRunner: Runner(defaultWorkingDirectory: subscriber)
        )
    }

    private func configure(_ repo: URL) async throws {
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
    }

    private func commit(named name: String, at repo: URL) async throws {
        try Data("\(name)\n".utf8).write(to: repo.appendingPathComponent(name))
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["add", name])
        _ = try await runner.run(["commit", "-m", "add \(name)"])
    }

    /// The canonical "merged on the server" journey: subscriber
    /// publishes feature/x, the server merges it into main and
    /// deletes the branch, subscriber fetch --prunes.
    private func mergeAndDeleteOnServer(_ fixture: Fixture, branch: String) async throws {
        let pub = Runner(defaultWorkingDirectory: fixture.publisher)
        _ = try await pub.run(["fetch", "origin"])
        _ = try await pub.run(["merge", "--ff-only", "origin/\(branch)"])
        _ = try await pub.run(["push", "origin", "main"])
        _ = try await pub.run(["push", "origin", "--delete", branch])
        _ = try await SyncOps(runner: fixture.subscriberRunner).fetchAll()
    }

    @Test("merged-then-deleted branch is stale and safe to delete")
    func mergedBranchIsSafe() async throws {
        let fixture = try await makeFixture("safe")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sub = fixture.subscriberRunner
        _ = try await sub.run(["switch", "-c", "feature/x"])
        try await commit(named: "feature.txt", at: fixture.subscriber)
        _ = try await sub.run(["push", "-u", "origin", "feature/x"])
        _ = try await sub.run(["switch", "main"])
        try await mergeAndDeleteOnServer(fixture, branch: "feature/x")

        let stale = try await BranchHygiene(runner: sub).staleBranches()

        let feature = try #require(stale.first { $0.name == "feature/x" })
        #expect(feature.safeToDelete)
        #expect(feature.unpushedCommitCount == 0)
        #expect(feature.formerUpstream == "origin/feature/x")
        #expect(!feature.isCurrent)
        #expect(stale.count == 1, "main is healthy and must not appear")
    }

    @Test("deleted-on-server branch with unpushed commits is stale but NOT safe")
    func unpushedBranchIsUnsafe() async throws {
        let fixture = try await makeFixture("unsafe")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sub = fixture.subscriberRunner
        _ = try await sub.run(["switch", "-c", "feature/wip"])
        try await commit(named: "one.txt", at: fixture.subscriber)
        _ = try await sub.run(["push", "-u", "origin", "feature/wip"])
        // Two MORE local commits the server never saw, then the server
        // deletes the branch unmerged.
        try await commit(named: "two.txt", at: fixture.subscriber)
        try await commit(named: "three.txt", at: fixture.subscriber)
        _ = try await sub.run(["switch", "main"])
        _ = try await Runner(defaultWorkingDirectory: fixture.publisher)
            .run(["push", "origin", "--delete", "feature/wip"])
        _ = try await SyncOps(runner: sub).fetchAll()

        let stale = try await BranchHygiene(runner: sub).staleBranches()

        let wip = try #require(stale.first { $0.name == "feature/wip" })
        #expect(!wip.safeToDelete)
        #expect(wip.unpushedCommitCount == 3, "all three commits exist nowhere else")
    }

    @Test("the checked-out branch is never classified safe")
    func currentBranchNeverSafe() async throws {
        let fixture = try await makeFixture("current")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sub = fixture.subscriberRunner
        _ = try await sub.run(["switch", "-c", "feature/here"])
        try await commit(named: "here.txt", at: fixture.subscriber)
        _ = try await sub.run(["push", "-u", "origin", "feature/here"])
        try await mergeAndDeleteOnServer(fixture, branch: "feature/here")
        // Still ON feature/here.

        let stale = try await BranchHygiene(runner: sub).staleBranches()

        let here = try #require(stale.first { $0.name == "feature/here" })
        #expect(here.isCurrent)
        #expect(!here.safeToDelete, "merged, but checked out — deletion must not be offered")
    }

    @Test("default-remote-ref falls back to origin/main when origin/HEAD is unset")
    func defaultRefFallback() async throws {
        let fixture = try await makeFixture("fallback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sub = fixture.subscriberRunner
        _ = try await sub.run(["remote", "set-head", "origin", "--delete"])

        let hygiene = BranchHygiene(runner: sub)
        #expect(try await hygiene.defaultRemoteRef() == "origin/main")
    }

    @Test("deleteBranch (-d) deletes a merged branch and refuses an unmerged one")
    func plainDeleteSemantics() async throws {
        let fixture = try await makeFixture("delete")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sub = fixture.subscriberRunner
        // Merged-into-HEAD branch: trivially deletable.
        _ = try await sub.run(["branch", "merged-twin"])
        // Unmerged branch with its own commit.
        _ = try await sub.run(["switch", "-c", "unmerged"])
        try await commit(named: "u.txt", at: fixture.subscriber)
        _ = try await sub.run(["switch", "main"])

        let hygiene = BranchHygiene(runner: sub)
        #expect(try await hygiene.deleteBranch(named: "merged-twin") == .deleted(branch: "merged-twin"))
        #expect(try await hygiene.deleteBranch(named: "unmerged") == .refusedNotMerged(branch: "unmerged"))
        // Force path takes it (callers pair this with an ADR 0033 snapshot).
        #expect(try await hygiene.forceDeleteBranch(named: "unmerged") == .deleted(branch: "unmerged"))
    }
}
