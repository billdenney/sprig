// SyncOpsRebaseTests.swift
//
// ADR 0071 amendment against real git: the explicit rebase-then-push
// follow-up's rebase half. Same bare-origin + publisher + subscriber
// fixture as SyncOpsPushTests. The load-bearing claims:
//
//   - a diverged branch gets its commits REPLAYED (linear history,
//     upstream is an ancestor afterward, worktree clean);
//   - a conflicted rebase is left IN PLACE (typed outcome, repo
//     mid-rebase, one `rebase --abort` restores the original tip);
//   - every precondition skip is typed and leaves the repo untouched.

import Foundation
@testable import GitCore
import Testing

// `.serialized`: multi-repo fixtures with pushes per test; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("SyncOps.rebaseOntoUpstream — against real git", .serialized)
struct SyncOpsRebaseTests {
    private struct Fixture {
        let root: URL
        let origin: URL
        let publisher: URL
        let subscriber: URL
    }

    private func makeFixture(_ label: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-rebaseops-\(label)-\(UUID().uuidString)")
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
        return Fixture(root: root, origin: origin, publisher: publisher, subscriber: subscriber)
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

    /// Publisher advances origin/main; subscriber commits locally and
    /// fetches — the canonical diverged state (ahead 1, behind 1).
    private func makeDiverged(
        _ label: String,
        conflicting: Bool = false
    ) async throws -> Fixture {
        let fixture = try await makeFixture(label)
        let publisherRunner = Runner(defaultWorkingDirectory: fixture.publisher)
        let subscriberRunner = Runner(defaultWorkingDirectory: fixture.subscriber)

        if conflicting {
            // Both sides edit seed.txt differently → rebase conflict.
            try Data("remote version\n".utf8)
                .write(to: fixture.publisher.appendingPathComponent("seed.txt"))
            _ = try await publisherRunner.run(["commit", "-am", "remote edit"])
            try Data("local version\n".utf8)
                .write(to: fixture.subscriber.appendingPathComponent("seed.txt"))
            _ = try await subscriberRunner.run(["commit", "-am", "local edit"])
        } else {
            try await commit(named: "remote.txt", at: fixture.publisher)
            try await commit(named: "local.txt", at: fixture.subscriber)
        }
        _ = try await publisherRunner.run(["push", "origin", "main"])
        _ = try await subscriberRunner.run(["fetch", "origin"])
        return fixture
    }

    @Test("diverged branch is replayed: linear history, clean tree, both sides' work present")
    func divergedRebases() async throws {
        let fixture = try await makeDiverged("replay")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)

        let outcome = try await SyncOps(runner: runner).rebaseOntoUpstream()

        #expect(outcome == .rebased(branch: "main", onto: "origin/main", replayed: 1))
        // Linear: the upstream tip is now an ancestor of HEAD…
        let ancestor = try await runner.run(
            ["merge-base", "--is-ancestor", "origin/main", "HEAD"],
            throwOnNonZero: false
        )
        #expect(ancestor.exitCode == 0, "upstream must be an ancestor after the replay")
        // …no merge commit was created…
        let mergeCount = try await runner.run(["rev-list", "--merges", "--count", "HEAD"])
        #expect(mergeCount.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        // …both sides' files exist, and the tree is clean.
        #expect(FileManager.default.fileExists(
            atPath: fixture.subscriber.appendingPathComponent("remote.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.subscriber.appendingPathComponent("local.txt").path
        ))
        let status = try await runner.run(["status", "--porcelain"])
        #expect(status.stdoutString.isEmpty)
    }

    @Test("conflicted rebase is left in place: typed outcome, mid-rebase markers, abort restores")
    func conflictedRebaseLeftInPlace() async throws {
        let fixture = try await makeDiverged("conflict", conflicting: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)
        let preRebaseHEAD = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let outcome = try await SyncOps(runner: runner).rebaseOntoUpstream()

        #expect(outcome == .conflicted(branch: "main", conflictedPathCount: 1))
        // The repo is genuinely mid-rebase — the resolver's domain.
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: fixture.subscriber)
        #expect(GitMetadataPaths.repoIsMidOperation(gitDir: gitDir))
        // One-tap undo works and restores the original tip.
        let abort = try await runner.run(["rebase", "--abort"], throwOnNonZero: false)
        #expect(abort.exitCode == 0)
        let restoredHEAD = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(restoredHEAD == preRebaseHEAD)
    }

    @Test("ahead-only and behind-only branches are notDiverged — other legs' jobs")
    func nonDivergedStates() async throws {
        let fixture = try await makeFixture("not-diverged")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)
        let sync = SyncOps(runner: runner)

        // Ahead-only.
        try await commit(named: "local.txt", at: fixture.subscriber)
        #expect(try await sync.rebaseOntoUpstream() == .notDiverged(branch: "main"))

        // Behind-only (push our commit away, then fall behind). The
        // publisher catches up first so ITS push fast-forwards.
        _ = try await runner.run(["push", "origin", "main"])
        let publisherRunner = Runner(defaultWorkingDirectory: fixture.publisher)
        _ = try await publisherRunner.run(["pull", "--ff-only"])
        try await commit(named: "remote.txt", at: fixture.publisher)
        _ = try await publisherRunner.run(["push", "origin", "main"])
        _ = try await runner.run(["fetch", "origin"])
        #expect(try await sync.rebaseOntoUpstream() == .notDiverged(branch: "main"))
    }

    @Test("dirty tracked modifications refuse the rewrite and leave the repo untouched")
    func dirtyWorktreeRefuses() async throws {
        let fixture = try await makeDiverged("dirty")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)
        try Data("uncommitted\n".utf8)
            .write(to: fixture.subscriber.appendingPathComponent("local.txt"))
        let preHEAD = try await runner.run(["rev-parse", "HEAD"]).stdoutString

        let outcome = try await SyncOps(runner: runner).rebaseOntoUpstream()

        #expect(outcome == .dirtyWorktree(branch: "main"))
        #expect(try await runner.run(["rev-parse", "HEAD"]).stdoutString == preHEAD)
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: fixture.subscriber)
        #expect(!GitMetadataPaths.repoIsMidOperation(gitDir: gitDir))
    }

    @Test("no upstream and detached HEAD are typed skips")
    func noUpstreamAndDetached() async throws {
        let fixture = try await makeFixture("skips")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)
        let sync = SyncOps(runner: runner)

        _ = try await runner.run(["switch", "-c", "feature/local-only"])
        #expect(
            try await sync.rebaseOntoUpstream()
                == .noUpstream(branch: "feature/local-only")
        )

        let head = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["switch", "--detach", head])
        #expect(try await sync.rebaseOntoUpstream() == .detachedHEAD)
    }
}
