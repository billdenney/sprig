// HistoryOpsTests.swift
//
// ADR 0082 against real git (never mocked), with a bare "origin"
// fixture so the shared-history oracle (`branch -r --contains`) is
// exercised for real. The load-bearing claims:
//
//   - reword replaces ONLY the message: tree, parent, and author
//     are byte-identical afterward;
//   - squash's new commit has the old tip's exact tree, sits on the
//     right parent, and replaces exactly N commits;
//   - anything reachable from a remote-tracking ref refuses — for
//     squash the check runs on the OLDEST affected commit;
//   - staged changes refuse (the amend-folds-them-in trap), and the
//     refusal leaves both the commit and the staged change intact.

import Foundation
@testable import GitCore
import Testing

@Suite("HistoryOps — reword + squash against real git", .serialized)
struct HistoryOpsTests {
    /// Repo with a bare `origin` and one PUSHED seed commit.
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-historyops-\(label)-\(UUID().uuidString)")
            .standardized
        let work = dir.appendingPathComponent("work")
        let origin = dir.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: work)
        _ = try await Runner(defaultWorkingDirectory: origin).run(["init", "--bare", "-b", "main"])
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["remote", "add", "origin", origin.path])
        try Data("seed\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        _ = try await runner.run(["push", "-u", "origin", "main"])
        return (dir, runner)
    }

    /// One local-only commit touching `name`.
    private func addLocalCommit(
        _ runner: Runner,
        in dir: URL,
        name: String,
        message: String
    ) async throws {
        try Data("\(message)\n".utf8)
            .write(to: dir.appendingPathComponent("work").appendingPathComponent(name))
        _ = try await runner.run(["add", name])
        _ = try await runner.run(["commit", "-m", message])
    }

    private func headField(_ runner: Runner, _ format: String) async throws -> String {
        try await runner.run(["log", "-1", "--format=\(format)"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("reword replaces only the message — tree, parent, author unchanged")
    func rewordMessageOnly() async throws {
        let (dir, runner) = try await makeRepo("reword")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await addLocalCommit(runner, in: dir, name: "b.txt", message: "draft wording")
        let treeBefore = try await headField(runner, "%T")
        let parentBefore = try await headField(runner, "%P")
        let authorBefore = try await headField(runner, "%an <%ae>")

        let outcome = try await HistoryOps(runner: runner)
            .rewordLastCommit(message: "feat: the real wording")

        guard case let .reworded(newSHA) = outcome else {
            Issue.record("expected .reworded, got \(outcome)")
            return
        }
        #expect(newSHA.count == 40)
        #expect(try await headField(runner, "%s") == "feat: the real wording")
        #expect(try await headField(runner, "%T") == treeBefore)
        #expect(try await headField(runner, "%P") == parentBefore)
        #expect(try await headField(runner, "%an <%ae>") == authorBefore)
    }

    @Test("reword refuses when HEAD is on a remote — shared history stays put")
    func rewordRefusesShared() async throws {
        let (dir, runner) = try await makeRepo("rewordshared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let headBefore = try await headField(runner, "%H")

        let outcome = try await HistoryOps(runner: runner)
            .rewordLastCommit(message: "rewrite the pushed seed")

        #expect(outcome == .refusedShared)
        #expect(try await headField(runner, "%H") == headBefore)
    }

    @Test("reword refuses staged changes and leaves both the commit and the stage intact")
    func rewordRefusesStaged() async throws {
        let (dir, runner) = try await makeRepo("rewordstaged")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await addLocalCommit(runner, in: dir, name: "b.txt", message: "local work")
        try Data("staged edit\n".utf8)
            .write(to: dir.appendingPathComponent("work").appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "b.txt"])
        let headBefore = try await headField(runner, "%H")

        let outcome = try await HistoryOps(runner: runner)
            .rewordLastCommit(message: "would swallow the stage")

        #expect(outcome == .refusedStagedChanges)
        #expect(try await headField(runner, "%H") == headBefore)
        let staged = try await runner.run(["diff", "--cached", "--name-only"])
        #expect(staged.stdoutString.contains("b.txt"), "the staged change must survive the refusal")
    }

    @Test("reword refuses mid-merge and on a detached HEAD")
    func rewordRefusesMidstreamAndDetached() async throws {
        let (dir, runner) = try await makeRepo("rewordguards")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        // Conflicted merge: diverge a.txt on a side branch and main.
        _ = try await runner.run(["switch", "-c", "side"])
        try Data("side\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "side edit"])
        _ = try await runner.run(["switch", "main"])
        try Data("main\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "main edit"])
        _ = try await runner.run(["merge", "side"], throwOnNonZero: false)

        #expect(
            try await HistoryOps(runner: runner)
                .rewordLastCommit(message: "x") == .refusedMidstream
        )

        _ = try await runner.run(["merge", "--abort"])
        _ = try await runner.run(["switch", "--detach", "HEAD"])
        #expect(
            try await HistoryOps(runner: runner)
                .rewordLastCommit(message: "x") == .refusedDetachedHEAD
        )
    }

    @Test("squash collapses exactly N commits onto the right parent with the old tip's tree")
    func squashCollapses() async throws {
        let (dir, runner) = try await makeRepo("squash")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await addLocalCommit(runner, in: dir, name: "b.txt", message: "wip 1")
        try await addLocalCommit(runner, in: dir, name: "c.txt", message: "wip 2")
        let treeBefore = try await headField(runner, "%T")
        let pushedSeed = try await runner.run(["rev-parse", "origin/main"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let outcome = try await HistoryOps(runner: runner)
            .squashLast(2, message: "feat: b and c together")

        guard case let .squashed(newSHA, replaced) = outcome else {
            Issue.record("expected .squashed, got \(outcome)")
            return
        }
        #expect(replaced == 2)
        #expect(newSHA.count == 40)
        #expect(try await headField(runner, "%T") == treeBefore, "squash must not change content")
        #expect(try await headField(runner, "%P") == pushedSeed, "new commit sits on the pushed seed")
        #expect(try await headField(runner, "%s") == "feat: b and c together")
        let localCount = try await runner.run(["rev-list", "--count", "HEAD", "--not", "--remotes"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(localCount == "1")
    }

    @Test("squash refuses when the range touches a pushed commit (oldest-commit check)")
    func squashRefusesShared() async throws {
        let (dir, runner) = try await makeRepo("squashshared")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Second PUSHED commit (so the root-range guard can't fire
        // first), then one local commit on top.
        try await addLocalCommit(runner, in: dir, name: "pushed.txt", message: "pushed work")
        _ = try await runner.run(["push", "origin", "main"])
        try await addLocalCommit(runner, in: dir, name: "b.txt", message: "local work")
        let headBefore = try await headField(runner, "%H")

        // 3 commits exist; the oldest of the squashed pair is PUSHED.
        let outcome = try await HistoryOps(runner: runner)
            .squashLast(2, message: "would rewrite pushed history")

        #expect(outcome == .refusedShared)
        #expect(try await headField(runner, "%H") == headBefore)
    }

    @Test("squash refuses count < 2 and ranges that would swallow the root commit")
    func squashRefusesDegenerateRanges() async throws {
        let (dir, runner) = try await makeRepo("squashranges")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await addLocalCommit(runner, in: dir, name: "b.txt", message: "local work")
        let ops = HistoryOps(runner: runner)

        #expect(try await ops.squashLast(1, message: "m") == .refusedNeedAtLeastTwo)
        // Only 2 commits exist in total — HEAD~3 reaches past the root.
        #expect(try await ops.squashLast(3, message: "m") == .refusedNotEnoughHistory)
    }

    @Test("squash refuses staged changes so they can't be folded into the squashed commit")
    func squashRefusesStaged() async throws {
        let (dir, runner) = try await makeRepo("squashstaged")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await addLocalCommit(runner, in: dir, name: "b.txt", message: "wip 1")
        try await addLocalCommit(runner, in: dir, name: "c.txt", message: "wip 2")
        try Data("staged edit\n".utf8)
            .write(to: dir.appendingPathComponent("work").appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "b.txt"])

        let outcome = try await HistoryOps(runner: runner)
            .squashLast(2, message: "m")

        #expect(outcome == .refusedStagedChanges)
    }
}
