// StatusViewModelTests.swift
//
// ADR 0064's Status surface against real git: one refresh answers
// "where does this repo stand?" — tree counts (shared classifier),
// branch relationships, parked-operation detection, and the safety
// net's size. `fetchNow()` is proven end-to-end against a bare
// origin: the behind-count appears only after the manual fetch.

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

// `.serialized`: real-git fixtures, some with pushes; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("StatusViewModel — repo dashboard (real git)", .serialized)
struct StatusViewModelTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-statusvm-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    private func summary(of vm: StatusViewModel) async throws -> RepoStatusSummary {
        let state = await vm.state
        guard case let .success(summary) = state else {
            throw NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected .success, got \(state)"
            ])
        }
        return summary
    }

    @Test("clean repo: zero counts, main branch, no mid-operation, empty safety net")
    func cleanRepoSummary() async throws {
        let (dir, runner) = try await makeRepo("clean")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = StatusViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let summary = try await summary(of: vm)
        #expect(summary.stagedCount == 0)
        #expect(summary.unstagedCount == 0)
        #expect(summary.untrackedCount == 0)
        #expect(summary.conflictedCount == 0)
        #expect(summary.branch?.head == "main")
        #expect(summary.midOperation == MidstreamOperation.none)
        #expect(summary.snapshotCount == 0)
        #expect(summary.backupCount == 0)
        #expect(summary.newestSafetyCopy == nil)
        #expect(summary.branches.count == 1)
        #expect(summary.currentBranchState?.upstreamShort == nil)
    }

    @Test("dirty repo counts each bucket once; an MM file is staged AND unstaged")
    func dirtyCounts() async throws {
        let (dir, runner) = try await makeRepo("dirty")
        defer { try? FileManager.default.removeItem(at: dir) }
        // a.txt: staged edit, then a further worktree edit → MM.
        try Data("staged\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        try Data("staged+more\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        // b.txt: brand-new, staged → A.
        try Data("new\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "b.txt"])
        // wip.txt: untracked.
        try Data("wip\n".utf8).write(to: dir.appendingPathComponent("wip.txt"))

        let vm = StatusViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let summary = try await summary(of: vm)
        #expect(summary.stagedCount == 2, "a.txt + b.txt")
        #expect(summary.unstagedCount == 1, "a.txt's post-stage edit")
        #expect(summary.untrackedCount == 1, "wip.txt")
        #expect(summary.conflictedCount == 0)
    }

    @Test("parked merge: conflicted count + midOperation == .merge")
    func parkedMergeSurfaceds() async throws {
        let (dir, runner) = try await makeRepo("midmerge")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await runner.run(["switch", "-c", "side"])
        try Data("side\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "side edit"])
        _ = try await runner.run(["switch", "main"])
        try Data("main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "main edit"])
        _ = try await runner.run(["merge", "side"], throwOnNonZero: false)

        let vm = StatusViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let summary = try await summary(of: vm)
        #expect(summary.conflictedCount == 1)
        #expect(summary.midOperation == .merge)
    }

    @Test("safety net: snapshot + backup counted, newest timestamp wins")
    func safetyNetCounts() async throws {
        let (dir, runner) = try await makeRepo("safety")
        defer { try? FileManager.default.removeItem(at: dir) }
        let older = Date(timeIntervalSince1970: 1_760_000_000)
        let newer = older.addingTimeInterval(900)
        _ = try await SnapshotWriter(runner: runner, clock: { older })
            .createSnapshot(op: SnapshotRefName.opMerge)
        try Data("dirty\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await WorktreeBackup(runner: runner, clock: { newer }).createBackupIfDirty()

        let vm = StatusViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let summary = try await summary(of: vm)
        #expect(summary.snapshotCount == 1)
        #expect(summary.backupCount == 1)
        #expect(summary.newestSafetyCopy == newer)
    }

    @Test("fetchNow: the behind-count appears only after the manual fetch")
    func fetchNowUpdatesRelationships() async throws {
        // Bare origin + publisher + subscriber; the publisher moves
        // the remote AFTER the subscriber's clone.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-statusvm-fetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootRunner = Runner(defaultWorkingDirectory: root)
        let origin = root.appendingPathComponent("origin.git")
        _ = try await rootRunner.run(["init", "--bare", "-b", "main", origin.path])
        let publisher = root.appendingPathComponent("publisher")
        _ = try await rootRunner.run(["clone", origin.path, publisher.path])
        let publisherRunner = Runner(defaultWorkingDirectory: publisher)
        _ = try await publisherRunner.run(["config", "user.email", "test@sprig.app"])
        _ = try await publisherRunner.run(["config", "user.name", "Sprig Test"])
        _ = try await publisherRunner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: publisher.appendingPathComponent("seed.txt"))
        _ = try await publisherRunner.run(["add", "seed.txt"])
        _ = try await publisherRunner.run(["commit", "-m", "seed"])
        _ = try await publisherRunner.run(["push", "origin", "main"])
        let subscriber = root.appendingPathComponent("subscriber")
        _ = try await rootRunner.run(["clone", origin.path, subscriber.path])
        let runner = Runner(defaultWorkingDirectory: subscriber)
        try Data("incoming\n".utf8).write(to: publisher.appendingPathComponent("incoming.txt"))
        _ = try await publisherRunner.run(["add", "incoming.txt"])
        _ = try await publisherRunner.run(["commit", "-m", "incoming"])
        _ = try await publisherRunner.run(["push", "origin", "main"])

        let vm = StatusViewModel(repoURL: subscriber, runner: runner)
        await vm.refresh()
        let before = try await summary(of: vm)
        #expect(before.currentBranchState?.behind == 0, "stale tracking ref pre-fetch")

        await vm.fetchNow()
        let after = try await summary(of: vm)
        #expect(after.currentBranchState?.behind == 1, "Fetch now refreshed the tracking ref")
        // ADR 0077: the same fetch answers "what changed?".
        let digests = try #require(after.fetchDigests)
        #expect(digests.count == 1)
        #expect(digests.first?.ref == "origin/main")
        #expect(digests.first?.commitCount == 1)
        #expect(digests.first?.authorCount == 1)
    }

    @Test("the summary carries HEAD's committer date for the stale-work nudge")
    func lastCommitDateSurfaces() async throws {
        let (dir, runner) = try await makeRepo("staleness")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = StatusViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let date = try #require(try await summary(of: vm).lastCommitDate)
        // The seed commit just happened; sanity-bound the parse
        // rather than pinning a clock we don't control.
        #expect(abs(date.timeIntervalSinceNow) < 600)
    }
}
