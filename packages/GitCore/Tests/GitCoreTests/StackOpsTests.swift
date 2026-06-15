// StackOpsTests.swift
//
// ADR 0085 against real git (never mocked). The load-bearing claims:
//
//   - restack replays a child's OWN commits onto its parent's moved
//     tip, for both an append-only parent move AND a parent rewrite
//     (the reword-survival test — the case a live merge-base would
//     fail by replaying the parent's orphaned commits);
//   - a conflicted replay PARKS git's rebase and `rebase --abort`
//     returns the child to its exact pre-restack tip;
//   - the recorded fork-point is re-frozen to the new parent tip on
//     success;
//   - the refusal matrix (no link, diverged fork, nothing to replay,
//     guard refusals) fires before any rewrite;
//   - the config CRUD round-trips, including a branch name with a dot
//     segment.

import Foundation
@testable import GitCore
import Testing

@Suite("StackOps — stacked-branch restack against real git", .serialized)
struct StackOpsTests {
    /// Bare origin + a pushed three-level stack:
    /// main ← feature-a (a1,a2) ← feature-b (b1,b2) ← feature-c (c1).
    /// All three feature branches are pushed (restack operates on
    /// pushed children — the ADR 0051 amendment's whole point). Links
    /// recorded via `recordStackLink`. Leaves HEAD on feature-c.
    private func makeStack(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-stackops-\(label)-\(UUID().uuidString)")
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
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        _ = try await runner.run(["remote", "add", "origin", origin.path])
        try Data("seed\n".utf8).write(to: work.appendingPathComponent("base.txt"))
        _ = try await runner.run(["add", "base.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        _ = try await runner.run(["push", "-u", "origin", "main"])

        try await commitFiles(runner, work, branchFrom: "main", branch: "feature-a", files: ["a1", "a2"])
        try await commitFiles(runner, work, branchFrom: "feature-a", branch: "feature-b", files: ["b1", "b2"])
        try await commitFiles(runner, work, branchFrom: "feature-b", branch: "feature-c", files: ["c1"])
        for b in ["feature-a", "feature-b", "feature-c"] {
            _ = try await runner.run(["push", "-u", "origin", b])
        }
        let stacks = StackOps(runner: runner)
        try await stacks.recordStackLink(child: "feature-a", parent: "main")
        try await stacks.recordStackLink(child: "feature-b", parent: "feature-a")
        try await stacks.recordStackLink(child: "feature-c", parent: "feature-b")
        return (dir, runner)
    }

    /// Branch `branch` from `branchFrom`, then add one commit per file
    /// name (each adds `<name>.txt`), leaving HEAD on `branch`.
    private func commitFiles(
        _ runner: Runner,
        _ work: URL,
        branchFrom: String,
        branch: String,
        files: [String]
    ) async throws {
        _ = try await runner.run(["switch", "-c", branch, branchFrom])
        for name in files {
            try Data("\(name)\n".utf8).write(to: work.appendingPathComponent("\(name).txt"))
            _ = try await runner.run(["add", "\(name).txt"])
            _ = try await runner.run(["commit", "-m", name])
        }
    }

    private func subjects(_ runner: Runner, _ ref: String) async throws -> [String] {
        try await runner.run(["log", "--format=%s", ref])
            .stdoutString.split(separator: "\n").map(String.init)
    }

    private func sha(_ runner: Runner, _ rev: String) async throws -> String {
        try await runner.run(["rev-parse", rev])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Link CRUD

    @Test("recordStackLink round-trips parent + frozen fork; unlink clears; children invert")
    func linkCrud() async throws {
        let (dir, runner) = try await makeStack("crud")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stacks = StackOps(runner: runner)

        #expect(try await stacks.recordedParent(of: "feature-b") == "feature-a")
        // The frozen fork = merge-base(feature-a, feature-b) at link
        // time = feature-a's tip when feature-b branched.
        let fork = try #require(try await stacks.recordedForkPoint(of: "feature-b"))
        #expect(fork.count == 40)
        #expect(try await stacks.stackChildren(of: "feature-a") == ["feature-b"])
        #expect(try await stacks.stackChildren(of: "feature-b") == ["feature-c"])

        try await stacks.unlinkStack(branch: "feature-b")
        #expect(try await stacks.recordedParent(of: "feature-b") == nil)
        #expect(try await stacks.recordedForkPoint(of: "feature-b") == nil)
        // Idempotent.
        try await stacks.unlinkStack(branch: "feature-b")
    }

    @Test("config CRUD survives a branch name with a dot segment")
    func dotSegmentBranchName() async throws {
        let (dir, runner) = try await makeStack("dotseg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stacks = StackOps(runner: runner)
        _ = try await runner.run(["switch", "-c", "feat.x", "main"])
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("work").appendingPathComponent("x.txt"))
        _ = try await runner.run(["add", "x.txt"])
        _ = try await runner.run(["commit", "-m", "x"])

        try await stacks.recordStackLink(child: "feat.x", parent: "main")

        #expect(try await stacks.recordedParent(of: "feat.x") == "main")
        #expect(try await stacks.stackChildren(of: "main").contains("feat.x"))
    }

    // MARK: - Restack (the core)

    @Test("append-only parent move: child's own commits replay onto the new tip; fork re-frozen")
    func appendOnlyRestack() async throws {
        let (dir, runner) = try await makeStack("append")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        // feature-a gets a review fixup a3.
        _ = try await runner.run(["switch", "feature-a"])
        try Data("a3\n".utf8).write(to: work.appendingPathComponent("a3.txt"))
        _ = try await runner.run(["add", "a3.txt"])
        _ = try await runner.run(["commit", "-m", "a3"])
        let newParentTip = try await sha(runner, "feature-a")

        let outcome = try await StackOps(runner: runner).restack(branch: "feature-b")

        guard case .completed = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(try await subjects(runner, "feature-b") == ["b2", "b1", "a3", "a2", "a1", "seed"])
        // Fork re-frozen to feature-a's new tip.
        #expect(try await StackOps(runner: runner).recordedForkPoint(of: "feature-b") == newParentTip)
    }

    @Test("sequential bottom-up restack of a multi-level stack (the v1 way; auto-walk deferred)")
    func sequentialMultiLevelRestack() async throws {
        let (dir, runner) = try await makeStack("multilevel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        let stacks = StackOps(runner: runner)
        // Move the bottom parent.
        _ = try await runner.run(["switch", "feature-a"])
        try Data("a3\n".utf8).write(to: work.appendingPathComponent("a3.txt"))
        _ = try await runner.run(["add", "a3.txt"])
        _ = try await runner.run(["commit", "-m", "a3"])

        // Restack the child, then the grandchild — bottom-up. The
        // grandchild's frozen fork (the old feature-b tip) is still its
        // own ancestor, so the staleness guard passes and c1 replays
        // exactly onto the rewritten feature-b.
        guard case .completed = try await stacks.restack(branch: "feature-b") else {
            Issue.record("feature-b restack should complete"); return
        }
        guard case .completed = try await stacks.restack(branch: "feature-c") else {
            Issue.record("feature-c restack should complete"); return
        }

        #expect(
            try await subjects(runner, "feature-c") == ["c1", "b2", "b1", "a3", "a2", "a1", "seed"],
            "c1 lands on the rewritten feature-b, every commit exactly once"
        )
    }

    @Test("reword-survival: a parent rewrite replays ONLY the child's commits, no duplication")
    func rewordSurvival() async throws {
        let (dir, runner) = try await makeStack("reword")
        defer { try? FileManager.default.removeItem(at: dir) }
        // feature-a's tip (a2) is reworded — rewrites the parent's own
        // commit, orphaning the original a2. A live merge-base would
        // slide to a1 and replay the orphaned a2 (a duplicate); the
        // frozen fork survives this.
        _ = try await runner.run(["switch", "feature-a"])
        _ = try await runner.run(["commit", "--amend", "-m", "a2-reworded"])

        let outcome = try await StackOps(runner: runner).restack(branch: "feature-b")

        guard case .completed = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(
            try await subjects(runner, "feature-b") == ["b2", "b1", "a2-reworded", "a1", "seed"],
            "exactly one a2 (the reworded one); the orphaned original must not reappear"
        )
    }

    @Test("a conflicted replay parks git's rebase; abort returns the child to its exact tip")
    func conflictParksAndAbort() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-stackops-conflict-\(UUID().uuidString)").standardized
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: work)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t"])
        _ = try await runner.run(["config", "user.name", "T"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        try Data("base\n".utf8).write(to: work.appendingPathComponent("conflict.txt"))
        _ = try await runner.run(["add", "conflict.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        // feature-a from main; feature-b from feature-a edits conflict.txt.
        _ = try await runner.run(["switch", "-c", "feature-a"])
        try Data("base\nA\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "a1"])
        _ = try await runner.run(["switch", "-c", "feature-b"])
        try Data("from-b\n".utf8).write(to: work.appendingPathComponent("conflict.txt"))
        _ = try await runner.run(["commit", "-am", "b-edits-conflict"])
        let stacks = StackOps(runner: runner)
        try await stacks.recordStackLink(child: "feature-b", parent: "feature-a")
        // feature-a's new tip edits the SAME file differently.
        _ = try await runner.run(["switch", "feature-a"])
        try Data("from-a\n".utf8).write(to: work.appendingPathComponent("conflict.txt"))
        _ = try await runner.run(["commit", "-am", "a-edits-conflict"])
        let beforeTip = try await sha(runner, "feature-b")

        let outcome = try await stacks.restack(branch: "feature-b")

        guard case let .conflicted(branch, count) = outcome else {
            Issue.record("expected .conflicted, got \(outcome)")
            return
        }
        #expect(branch == "feature-b")
        #expect(count == 1)
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: work)
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: gitDir) == .rebase)

        _ = try await runner.run(["rebase", "--abort"])
        #expect(try await sha(runner, "feature-b") == beforeTip, "abort returns the child to its exact pre-restack tip")
    }
}

/// Conflict-path re-freeze + the refusal matrix (a same-file extension
/// keeps the suite under the type-body length cap; the private helpers
/// above stay visible).
extension StackOpsTests {
    @Test("conflict → resolve+continue re-freezes the fork: the next restack replays no orphaned parent commits")
    func conflictResolvedRestackRefreezesFork() async throws {
        // Regression for the review-found bug: the re-freeze of
        // sprigBase used to happen only on the clean rebase path, so a
        // conflict-resolved restack left a stale fork that, on the NEXT
        // restack after a parent rewrite, replayed the parent's own
        // (orphaned) commits. The transient sprigPendingBase self-heal
        // fixes it.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-stackops-refreeze-\(UUID().uuidString)").standardized
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: work)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t"])
        _ = try await runner.run(["config", "user.name", "T"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        try Data("seed\n".utf8).write(to: work.appendingPathComponent("base.txt"))
        _ = try await runner.run(["add", "base.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        // feature-a:a1 sets a.txt; feature-b:b1 modifies a.txt (so the
        // first restack conflicts).
        _ = try await runner.run(["switch", "-c", "feature-a"])
        try Data("A1\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "a1"])
        _ = try await runner.run(["switch", "-c", "feature-b"])
        try Data("B1\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "b1"])
        let stacks = StackOps(runner: runner)
        try await stacks.recordStackLink(child: "feature-b", parent: "feature-a")
        // Parent moves (a2 sets a.txt differently) → restack#1 conflicts.
        _ = try await runner.run(["switch", "feature-a"])
        try Data("A2\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "a2"])
        _ = try await runner.run(["switch", "feature-b"])
        guard case .conflicted = try await stacks.restack(branch: "feature-b") else {
            Issue.record("restack#1 should conflict"); return
        }
        // Resolve + continue (the stack-unaware resolver path).
        try Data("RESOLVED\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["-c", "core.editor=true", "rebase", "--continue"])

        // Parent reworded, changing a DIFFERENT file (z.txt) so the
        // child's own commit (a.txt) won't conflict on restack#2 — the
        // only way restack#2 can fail is by replaying the orphaned a2.
        _ = try await runner.run(["switch", "feature-a"])
        try Data("Z\n".utf8).write(to: work.appendingPathComponent("z.txt"))
        _ = try await runner.run(["add", "z.txt"])
        _ = try await runner.run(["commit", "--amend", "-m", "a2-reworded"])
        _ = try await runner.run(["switch", "feature-b"])

        // restack#2 must self-heal (promote the pending fork) and replay
        // ONLY b1 — clean, no orphaned a2.
        guard case .completed = try await stacks.restack(branch: "feature-b") else {
            Issue.record("restack#2 should complete cleanly after the fork re-freeze"); return
        }
        #expect(
            try await subjects(runner, "feature-b") == ["b1", "a2-reworded", "a1", "seed"],
            "exactly one a2 (the reworded one); the orphaned original must not be replayed"
        )
        #expect(
            try String(contentsOf: work.appendingPathComponent("a.txt"), encoding: .utf8) == "RESOLVED\n"
        )
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("z.txt").path))
    }

    // MARK: - Refusals

    @Test("no recorded link refuses; a diverged fork refuses; nothing-to-replay refuses")
    func restackRefusals() async throws {
        let (dir, runner) = try await makeStack("refuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        let stacks = StackOps(runner: runner)

        // Unlinked branch.
        _ = try await runner.run(["switch", "-c", "loner", "main"])
        try Data("l\n".utf8).write(to: work.appendingPathComponent("l.txt"))
        _ = try await runner.run(["add", "l.txt"])
        _ = try await runner.run(["commit", "-m", "l"])
        #expect(try await stacks.restack(branch: "loner") == .refusedNoParentRecorded)

        // Diverged fork: reset feature-b below its recorded fork.
        _ = try await runner.run(["switch", "feature-b"])
        _ = try await runner.run(["reset", "--hard", "main"])
        #expect(try await stacks.restack(branch: "feature-b") == .refusedForkPointDiverged)

        // Nothing to replay: a child with no own commits beyond the fork.
        _ = try await runner.run(["switch", "-c", "feature-empty", "feature-a"])
        try await stacks.recordStackLink(child: "feature-empty", parent: "feature-a")
        #expect(try await stacks.restack(branch: "feature-empty") == .refusedNothingToRestack)
    }

    @Test("guard refusals wire through: detached HEAD, staged changes, dirty worktree")
    func guardRefusals() async throws {
        let (dir, runner) = try await makeStack("guards")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        let stacks = StackOps(runner: runner)

        _ = try await runner.run(["switch", "feature-b"])
        try Data("dirty\n".utf8).write(to: work.appendingPathComponent("b1.txt"))
        #expect(try await stacks.restack(branch: "feature-b") == .refusedDirtyWorktree)

        _ = try await runner.run(["add", "b1.txt"])
        #expect(try await stacks.restack(branch: "feature-b") == .refusedStagedChanges)
        _ = try await runner.run(["reset", "--hard", "HEAD"])

        _ = try await runner.run(["switch", "--detach", "HEAD"])
        #expect(try await stacks.restack(branch: "feature-b") == .refusedDetachedHEAD)
    }
}
