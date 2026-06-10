// StashOpsTests.swift
//
// ADR 0069 stash primitives against real git (never mocked). The
// outcome contract under test: push reports created-vs-nothing via
// refs/stash movement (not message parsing); a conflicted pop reports
// keptDueToConflict AND verifiably keeps the entry.

import Foundation
@testable import GitCore
import Testing

@Suite("StashOps — push/pop against real git")
struct StashOpsTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-stashops-\(label)-\(UUID().uuidString)")
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

    private func worktreeIsClean(_ runner: Runner) async throws -> Bool {
        let status = try await runner.run(["status", "--porcelain", "-z"])
        return status.stdout.isEmpty
    }

    private func stashExists(_ runner: Runner) async throws -> Bool {
        let result = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "refs/stash"],
            throwOnNonZero: false
        )
        return result.exitCode == 0
    }

    @Test("push on a dirty tree creates an entry and leaves the tree clean")
    func pushCreatesEntry() async throws {
        let (dir, runner) = try await makeRepo("push")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("edited\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let outcome = try await StashOps(runner: runner).push(message: "test stash")

        guard case let .created(sha) = outcome else {
            Issue.record("expected .created, got \(outcome)")
            return
        }
        #expect(sha.count == 40)
        #expect(try await worktreeIsClean(runner))
        #expect(try await stashExists(runner))
    }

    @Test("push includes untracked files by default; pop brings them back")
    func pushIncludesUntracked() async throws {
        let (dir, runner) = try await makeRepo("untracked")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scratch = dir.appendingPathComponent("scratch.txt")
        try Data("untracked work\n".utf8).write(to: scratch)

        let stash = StashOps(runner: runner)
        let pushed = try await stash.push(message: "with untracked")
        guard case .created = pushed else {
            Issue.record("expected .created, got \(pushed)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.path))

        let popped = try await stash.pop()
        #expect(popped == .applied)
        #expect(FileManager.default.fileExists(atPath: scratch.path))
        #expect(try await !stashExists(runner))
    }

    @Test("push on a clean tree reports nothingToStash")
    func pushOnCleanTree() async throws {
        let (dir, runner) = try await makeRepo("clean")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try await StashOps(runner: runner).push(message: "no-op")

        #expect(outcome == .nothingToStash)
        #expect(try await !stashExists(runner))
    }

    @Test("conflicted pop reports keptDueToConflict and the entry survives")
    func conflictedPopKeepsEntry() async throws {
        let (dir, runner) = try await makeRepo("conflict")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stash = StashOps(runner: runner)

        // Stash an edit to a.txt, then move the branch underneath it
        // with a different committed edit to the same lines.
        try Data("stashed edit\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await stash.push(message: "will conflict")
        try Data("committed rival\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "rival change"])

        let outcome = try await stash.pop()

        guard case .keptDueToConflict = outcome else {
            Issue.record("expected .keptDueToConflict, got \(outcome)")
            return
        }
        #expect(try await stashExists(runner), "git must keep the entry on a conflicted pop")
    }

    @Test("pop with no stash entries throws")
    func popWithoutStashThrows() async throws {
        let (dir, runner) = try await makeRepo("empty-pop")
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: GitError.self) {
            try await StashOps(runner: runner).pop()
        }
    }
}
