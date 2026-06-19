// MultiRepoStatusViewModelTests.swift
//
// ADR 0094 Option 2's roll-up against real git: several repos in
// distinct states (clean, dirty, ahead, conflicted) fold into one
// aggregate whose every count is pinned exactly. The empty set and an
// unreadable root prove graceful degradation — the roll-up never
// crashes and the bad root is counted, not dropped.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

// `.serialized`: real-git fixtures, some pushing to a bare origin; see
// StatusViewModelTests for the Windows-VM load rationale.
@Suite("MultiRepoStatusViewModel — cross-repo roll-up (real git)", .serialized)
struct MultiRepoStatusViewModelTests {
    /// A fresh repo with one seed commit on `main`. Returns its root.
    private func seededRepo(_ label: String) async throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-multirepo-\(label)-\(UUID().uuidString)")
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
        return dir
    }

    /// Dirty the repo: one untracked file (one unstaged bucket member).
    private func dirty(_ dir: URL) async throws {
        try Data("wip\n".utf8).write(to: dir.appendingPathComponent("wip.txt"))
    }

    /// Leave a parked merge with a conflicted path.
    private func parkedConflict(_ dir: URL) async throws {
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["switch", "-c", "side"])
        try Data("side\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "side edit"])
        _ = try await runner.run(["switch", "main"])
        try Data("main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "main edit"])
        _ = try await runner.run(["merge", "side"], throwOnNonZero: false)
    }

    /// A bare origin with a publisher that has pushed an extra commit,
    /// and a subscriber clone whose tracking ref already sees the gap
    /// (cloned after the second push). Returns the subscriber root.
    private func aheadBehindSubscriber(_ label: String) async throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-multirepo-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootRunner = Runner(defaultWorkingDirectory: root)
        let origin = root.appendingPathComponent("origin.git")
        _ = try await rootRunner.run(["init", "--bare", "-b", "main", origin.path])
        let publisher = root.appendingPathComponent("publisher")
        _ = try await rootRunner.run(["clone", origin.path, publisher.path])
        let pub = Runner(defaultWorkingDirectory: publisher)
        _ = try await pub.run(["config", "user.email", "test@sprig.app"])
        _ = try await pub.run(["config", "user.name", "Sprig Test"])
        _ = try await pub.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: publisher.appendingPathComponent("seed.txt"))
        _ = try await pub.run(["add", "seed.txt"])
        _ = try await pub.run(["commit", "-m", "seed"])
        _ = try await pub.run(["push", "origin", "main"])
        try Data("incoming\n".utf8).write(to: publisher.appendingPathComponent("incoming.txt"))
        _ = try await pub.run(["add", "incoming.txt"])
        _ = try await pub.run(["commit", "-m", "incoming"])
        _ = try await pub.run(["push", "origin", "main"])
        // Clone AFTER the second push so the tracking ref is already
        // one commit ahead of the checked-out tip → behind == 1 with no
        // fetch needed.
        let subscriber = root.appendingPathComponent("subscriber")
        _ = try await rootRunner.run(["clone", origin.path, subscriber.path])
        let sub = Runner(defaultWorkingDirectory: subscriber)
        // Reset the working tip back one commit so it trails its own
        // tracking ref by exactly one.
        _ = try await sub.run(["reset", "--hard", "HEAD~1"])
        return subscriber
    }

    private func rollup(of vm: MultiRepoStatusViewModel) async throws -> RepoRollup {
        let state = await vm.state
        guard case let .success(rollup) = state else {
            throw NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected .success, got \(state)"
            ])
        }
        return rollup
    }

    @Test("empty set: a valid, all-clean roll-up with zero counts")
    func emptySet() async throws {
        let vm = MultiRepoStatusViewModel(repoURLs: [])
        await vm.refresh()
        let rollup = try await rollup(of: vm)
        #expect(rollup.repos.isEmpty)
        #expect(rollup.readableCount == 0)
        #expect(rollup.failedCount == 0)
        #expect(rollup.dirtyCount == 0)
        #expect(rollup.conflictedCount == 0)
        #expect(rollup.totalAhead == 0)
        #expect(rollup.totalBehind == 0)
        #expect(rollup.allClean)
    }

    @Test("four distinct states fold into one exact aggregate")
    func mixedRollup() async throws {
        let clean = try await seededRepo("clean")
        let dirtyRepo = try await seededRepo("dirty")
        try await dirty(dirtyRepo)
        let conflicted = try await seededRepo("conflict")
        try await parkedConflict(conflicted)
        let behind = try await aheadBehindSubscriber("behind")
        defer {
            for dir in [clean, dirtyRepo, conflicted] {
                try? FileManager.default.removeItem(at: dir)
            }
            // behind's root is the parent of the subscriber dir.
            try? FileManager.default.removeItem(at: behind.deletingLastPathComponent())
        }

        let vm = MultiRepoStatusViewModel(repoURLs: [clean, dirtyRepo, conflicted, behind])
        await vm.refresh()
        let rollup = try await rollup(of: vm)

        #expect(rollup.repos.count == 4)
        #expect(rollup.readableCount == 4)
        #expect(rollup.failedCount == 0)
        #expect(rollup.dirtyCount == 2, "dirtyRepo (untracked) + conflicted (MM tree)")
        #expect(rollup.conflictedCount == 1, "only the parked merge")
        #expect(rollup.totalAhead == 0)
        #expect(rollup.totalBehind == 1, "the subscriber trails its tracking ref by one")
        #expect(!rollup.allClean)
    }

    @Test("order is preserved and rows carry the right per-repo verdicts")
    func rowOrderAndVerdicts() async throws {
        let clean = try await seededRepo("ord-clean")
        let conflicted = try await seededRepo("ord-conflict")
        try await parkedConflict(conflicted)
        defer {
            try? FileManager.default.removeItem(at: clean)
            try? FileManager.default.removeItem(at: conflicted)
        }

        let vm = MultiRepoStatusViewModel(repoURLs: [clean, conflicted])
        await vm.refresh()
        let rollup = try await rollup(of: vm)

        #expect(rollup.repos.map(\.repoURL) == [clean, conflicted])
        #expect(!rollup.repos[0].failed)
        #expect(!rollup.repos[0].isDirty)
        #expect(!rollup.repos[0].hasConflict)
        #expect(rollup.repos[1].hasConflict)
        #expect(rollup.repos[1].isDirty)
    }

    @Test("an unreadable root degrades to a failed entry, not a crash")
    func unreadableRootDegrades() async throws {
        let good = try await seededRepo("good")
        // A directory that exists but is not a git repo: git status
        // errors, so the per-repo refresh fails.
        let notARepo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-multirepo-notarepo-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: good)
            try? FileManager.default.removeItem(at: notARepo)
        }

        let vm = MultiRepoStatusViewModel(repoURLs: [good, notARepo])
        await vm.refresh()
        let rollup = try await rollup(of: vm)

        #expect(rollup.repos.count == 2)
        #expect(rollup.readableCount == 1)
        #expect(rollup.failedCount == 1)
        #expect(rollup.repos[1].failed)
        #expect(rollup.repos[1].failure != nil)
        #expect(rollup.repos[1].summary == nil)
        // A failed read is neither dirty nor conflicted (state unknown).
        #expect(!rollup.repos[1].isDirty)
        #expect(!rollup.repos[1].hasConflict)
        // The good repo still reads through.
        #expect(!rollup.repos[0].failed)
        // A failed read is NOT "clean": even though the readable repo is
        // clean, allClean must be false because one repo couldn't be read.
        #expect(!rollup.allClean)
    }

    @Test("refresh is re-runnable: a row goes dirty on the second pass")
    func reRunnable() async throws {
        let repo = try await seededRepo("rerun")
        defer { try? FileManager.default.removeItem(at: repo) }

        let vm = MultiRepoStatusViewModel(repoURLs: [repo])
        await vm.refresh()
        #expect(try await rollup(of: vm).dirtyCount == 0)

        try await dirty(repo)
        await vm.refresh()
        #expect(try await rollup(of: vm).dirtyCount == 1)
    }
}
