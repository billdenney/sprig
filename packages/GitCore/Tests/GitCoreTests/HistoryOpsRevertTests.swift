// HistoryOpsRevertTests.swift
//
// ADR 0084 against real git (never mocked). The load-bearing claims:
//
//   - a clean revert inverts exactly the target commit's change in a
//     NEW commit (history is untouched — additive);
//   - a conflicted revert PARKS git's revert (`REVERT_HEAD`) and
//     `git revert --abort` returns to the exact pre-revert tip;
//   - merge commits and unknown SHAs are typed refusals, not git
//     stderr surprises.

import Foundation
@testable import GitCore
import Testing

@Suite("HistoryOps — revert against real git", .serialized)
struct HistoryOpsRevertTests {
    /// Repo with three commits: seed(a.txt="seed"), B(b.txt),
    /// C(a.txt="from-C").
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-revert-\(label)-\(UUID().uuidString)")
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
        try Data("B\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "b.txt"])
        _ = try await runner.run(["commit", "-m", "B"])
        try Data("from-C\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "C"])
        return (dir, runner)
    }

    private func sha(_ runner: Runner, _ rev: String) async throws -> String {
        try await runner.run(["rev-parse", rev])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("a clean revert inverts the commit's change in a NEW commit")
    func cleanRevert() async throws {
        let (dir, runner) = try await makeRepo("clean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bSHA = try await sha(runner, "HEAD~1")
        let tipBefore = try await sha(runner, "HEAD")

        let outcome = try await HistoryOps(runner: runner).revert(bSHA)

        guard case let .reverted(newSHA) = outcome else {
            Issue.record("expected .reverted, got \(outcome)")
            return
        }
        #expect(newSHA != tipBefore)
        #expect(try await sha(runner, "HEAD~1") == tipBefore, "additive: old tip is the parent")
        let subject = try await runner.run(["log", "-1", "--format=%s"]).stdoutString
        #expect(subject.hasPrefix("Revert \"B\""))
        #expect(
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path),
            "B added b.txt; the revert removes it"
        )
        #expect(
            try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
                == "from-C\n",
            "C's change is untouched"
        )
    }

    @Test("a conflicted revert parks REVERT_HEAD; abort returns to the exact tip")
    func conflictedRevertParks() async throws {
        let (dir, runner) = try await makeRepo("conflict")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Reverting C's a.txt edit after D rewrote the same line.
        let cSHA = try await sha(runner, "HEAD")
        try Data("from-D\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "D"])
        let tipBefore = try await sha(runner, "HEAD")

        let outcome = try await HistoryOps(runner: runner).revert(cSHA)

        guard case let .conflicted(pathCount) = outcome else {
            Issue.record("expected .conflicted, got \(outcome)")
            return
        }
        #expect(pathCount == 1)
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: dir)
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: gitDir) == .revert)

        _ = try await runner.run(["revert", "--abort"])
        #expect(try await sha(runner, "HEAD") == tipBefore)
    }

    @Test("merge commits and unknown SHAs are typed refusals")
    func mergeAndUnknownRefuse() async throws {
        let (dir, runner) = try await makeRepo("refusals")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Build a merge commit: branch off seed, then merge main in.
        _ = try await runner.run(["switch", "-c", "side", "HEAD~2"])
        try Data("side\n".utf8).write(to: dir.appendingPathComponent("side.txt"))
        _ = try await runner.run(["add", "side.txt"])
        _ = try await runner.run(["commit", "-m", "side"])
        _ = try await runner.run(["merge", "--no-edit", "main"])
        let ops = HistoryOps(runner: runner)
        let mergeSHA = try await sha(runner, "HEAD")

        #expect(try await ops.revert(mergeSHA) == .refusedMergeCommit)
        #expect(
            try await ops.revert("0123456789abcdef0123456789abcdef01234567")
                == .refusedUnknownCommit
        )
    }

    @Test("a dirty worktree refuses before any git revert runs")
    func dirtyWorktreeRefuses() async throws {
        let (dir, runner) = try await makeRepo("dirty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bSHA = try await sha(runner, "HEAD~1")
        try Data("uncommitted\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        #expect(try await HistoryOps(runner: runner).revert(bSHA) == .refusedDirtyWorktree)
    }
}
