// RebasePlanOpsTests.swift
//
// ADR 0083 against real git (never mocked). The load-bearing claims:
//
//   - the printf sequence.editor drives git's own sequencer: a
//     reorder lands commits in the planned order, fixup folds
//     content while keeping the target's message, drop removes a
//     commit and its content;
//   - a conflicted replay PARKS git's rebase (markers present) and
//     `rebase --abort` returns to the exact pre-plan tip;
//   - plans that aren't a permutation of the unpushed range (or
//     start with a fixup, or carry malformed SHAs) refuse before
//     any git rewrite runs;
//   - the unpushed range reaching the root commit rides --root.

import Foundation
@testable import GitCore
import Testing

@Suite("RebasePlanOps — plan-driven rebase against real git", .serialized)
struct RebasePlanOpsTests {
    /// Repo with a bare `origin`, one PUSHED seed, and three
    /// local-only commits B, C, D (each adding its own file).
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-rebaseplan-\(label)-\(UUID().uuidString)")
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
        for (file, message) in [("b.txt", "B"), ("c.txt", "C"), ("d.txt", "D")] {
            try Data("\(message)\n".utf8).write(to: work.appendingPathComponent(file))
            _ = try await runner.run(["add", file])
            _ = try await runner.run(["commit", "-m", message])
        }
        return (dir, runner)
    }

    private func subjects(_ runner: Runner) async throws -> [String] {
        try await runner.run(["log", "--format=%s"])
            .stdoutString.split(separator: "\n").map(String.init)
    }

    @Test("unpushedCommits lists the rewritable range oldest first")
    func unpushedOldestFirst() async throws {
        let (dir, runner) = try await makeRepo("list")
        defer { try? FileManager.default.removeItem(at: dir) }

        let unpushed = try await RebasePlanOps(runner: runner).unpushedCommits()

        #expect(unpushed.map(\.subject) == ["B", "C", "D"])
        for commit in unpushed {
            #expect(commit.sha.count == 40)
        }
    }

    @Test("a reorder plan lands commits in todo order")
    func reorderPlan() async throws {
        let (dir, runner) = try await makeRepo("reorder")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ops = RebasePlanOps(runner: runner)
        let unpushed = try await ops.unpushedCommits()
        let bySubject = Dictionary(uniqueKeysWithValues: unpushed.map { ($0.subject, $0.sha) })

        let outcome = try await ops.apply([
            RebaseStep(.pick, #require(bySubject["D"])),
            RebaseStep(.pick, #require(bySubject["B"])),
            RebaseStep(.pick, #require(bySubject["C"]))
        ])

        guard case .completed = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(try await subjects(runner) == ["C", "B", "D", "seed"])
        for file in ["b.txt", "c.txt", "d.txt"] {
            let path = dir.appendingPathComponent("work").appendingPathComponent(file).path
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test("fixup folds content into the previous pick, keeping its message; drop removes")
    func fixupAndDrop() async throws {
        let (dir, runner) = try await makeRepo("fixupdrop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ops = RebasePlanOps(runner: runner)
        let unpushed = try await ops.unpushedCommits()
        let bySubject = Dictionary(uniqueKeysWithValues: unpushed.map { ($0.subject, $0.sha) })

        let outcome = try await ops.apply([
            RebaseStep(.pick, #require(bySubject["B"])),
            RebaseStep(.fixup, #require(bySubject["C"])),
            RebaseStep(.drop, #require(bySubject["D"]))
        ])

        guard case .completed = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(try await subjects(runner) == ["B", "seed"], "C folds into B; D is gone")
        let work = dir.appendingPathComponent("work")
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("c.txt").path))
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("d.txt").path))
    }

    @Test("a conflicted replay parks git's rebase; abort returns to the exact pre-plan tip")
    func conflictParksAndAbortRestores() async throws {
        let (dir, runner) = try await makeRepo("conflict")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        // Two commits editing the SAME line of a.txt — reordering
        // them cannot replay cleanly.
        try Data("from-E\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "E"])
        try Data("from-F\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "F"])
        let ops = RebasePlanOps(runner: runner)
        let tipBefore = try await runner.run(["rev-parse", "HEAD"]).stdoutString
        let unpushed = try await ops.unpushedCommits()
        let bySubject = Dictionary(uniqueKeysWithValues: unpushed.map { ($0.subject, $0.sha) })

        let outcome = try await ops.apply([
            RebaseStep(.pick, #require(bySubject["F"])),
            RebaseStep(.pick, #require(bySubject["E"])),
            RebaseStep(.pick, #require(bySubject["B"])),
            RebaseStep(.pick, #require(bySubject["C"])),
            RebaseStep(.pick, #require(bySubject["D"]))
        ])

        guard case let .conflicted(pathCount) = outcome else {
            Issue.record("expected .conflicted, got \(outcome)")
            return
        }
        #expect(pathCount == 1)
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: work)
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: gitDir) == .rebase)

        _ = try await runner.run(["rebase", "--abort"])
        let tipAfter = try await runner.run(["rev-parse", "HEAD"]).stdoutString
        #expect(tipAfter == tipBefore, "abort must return to the exact pre-plan tip")
    }

    @Test("invalid plans refuse before any rewrite: coverage, fixup-first, malformed SHA")
    func invalidPlansRefuse() async throws {
        let (dir, runner) = try await makeRepo("invalid")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ops = RebasePlanOps(runner: runner)
        let unpushed = try await ops.unpushedCommits()
        let tipBefore = try await runner.run(["rev-parse", "HEAD"]).stdoutString

        // Missing a commit.
        let partial = try await ops.apply([RebaseStep(.pick, unpushed[0].sha)])
        guard case .invalidPlan = partial else {
            Issue.record("expected .invalidPlan for partial coverage, got \(partial)")
            return
        }
        // Fixup with nothing before it.
        let fixupFirst = try await ops.apply([
            RebaseStep(.fixup, unpushed[0].sha),
            RebaseStep(.pick, unpushed[1].sha),
            RebaseStep(.pick, unpushed[2].sha)
        ])
        guard case .invalidPlan = fixupFirst else {
            Issue.record("expected .invalidPlan for fixup-first, got \(fixupFirst)")
            return
        }
        // Malformed SHA (also the injection guard).
        let malformed = try await ops.apply([
            RebaseStep(.pick, "$(rm -rf /)"),
            RebaseStep(.pick, unpushed[1].sha),
            RebaseStep(.pick, unpushed[2].sha)
        ])
        guard case .invalidPlan = malformed else {
            Issue.record("expected .invalidPlan for malformed SHA, got \(malformed)")
            return
        }
        #expect(try await runner.run(["rev-parse", "HEAD"]).stdoutString == tipBefore)
    }

    @Test("refusals: all pushed, dirty worktree, staged changes")
    func refusals() async throws {
        let (dir, runner) = try await makeRepo("refusals")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        let ops = RebasePlanOps(runner: runner)
        let unpushed = try await ops.unpushedCommits()
        let plan = unpushed.map { RebaseStep(.pick, $0.sha) }

        try Data("dirty\n".utf8).write(to: work.appendingPathComponent("b.txt"))
        #expect(try await ops.apply(plan) == .refusedDirtyWorktree)

        _ = try await runner.run(["add", "b.txt"])
        #expect(try await ops.apply(plan) == .refusedStagedChanges)
        _ = try await runner.run(["reset", "--hard", "HEAD"])

        _ = try await runner.run(["push", "origin", "main"])
        #expect(try await ops.apply(plan) == .refusedNothingToRebase)
    }

    @Test("a range reaching the root commit rides --root (repo with no remote)")
    func rootRangeWithoutRemote() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-rebaseplan-root-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t"])
        _ = try await runner.run(["config", "user.name", "T"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        for (file, message) in [("a.txt", "first"), ("b.txt", "second")] {
            try Data("\(message)\n".utf8).write(to: dir.appendingPathComponent(file))
            _ = try await runner.run(["add", file])
            _ = try await runner.run(["commit", "-m", message])
        }
        let ops = RebasePlanOps(runner: runner)
        let unpushed = try await ops.unpushedCommits()
        #expect(unpushed.map(\.subject) == ["first", "second"])

        let outcome = try await ops.apply([
            RebaseStep(.pick, unpushed[0].sha),
            RebaseStep(.fixup, unpushed[1].sha)
        ])

        guard case .completed = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(try await subjects(runner) == ["first"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
    }
}
