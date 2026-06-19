// AgentReviewViewModelTests.swift
//
// ADR 0088 — the agent-review surface. Real git in temp dirs:
//   * an external commit shows up in the report; a Sprig-authored one
//     does not.
//   * stage / unstage move a worktree change in and out of the index.
//   * split-a-commit: snapshot-first `reset --soft` leaves the commit's
//     changes in the index, then region staging carves the first piece
//     out byte-exactly; the snapshot is minted.
//   * undo restores the pre-split HEAD SHA-exactly through the Recover
//     path (the undo-round-trip rule).

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

@Suite("AgentReviewViewModel — review/stage/split/undo (real git)", .serialized)
struct AgentReviewViewModelTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-arvm-\(label)-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        return (dir, runner)
    }

    private func head(_ runner: Runner) async throws -> String {
        try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Review

    @Test("refresh surfaces an external commit, not a Sprig-authored one")
    func refreshSurfacesExternal() async throws {
        let (dir, runner) = try await makeRepo("review")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "base"])
        let base = try await head(runner)
        // Sprig checkpoints here; an outside commit lands next.
        try await OperationProvenance(runner: runner).recordHeads(["refs/heads/main": base])
        try Data("2\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "outside"])
        let outside = try await head(runner)

        let vm = AgentReviewViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let report = await vm.report
        #expect(report.commits.map(\.sha) == [outside])
        #expect(await vm.state.successValue == .reviewed(externalCommitCount: 1, headMoved: true))
        // A diff was fetched for the reviewable commit.
        #expect(await (vm.commitDiffs[outside]?.contains("b.txt")) == true)
    }

    // MARK: - Stage / unstage

    @Test("stage and unstage move a worktree change in and out of the index")
    func stageUnstage() async throws {
        let (dir, runner) = try await makeRepo("stage")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "base"])
        try Data("changed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let vm = AgentReviewViewModel(repoURL: dir, runner: runner)
        await vm.stage("a.txt")
        #expect(await vm.state.successValue == .staged("a.txt"))
        // Staged: `git diff --cached` is non-empty.
        #expect(try await !runner.run(["diff", "--cached", "--name-only"]).stdoutString.isEmpty)

        await vm.unstage("a.txt")
        #expect(await vm.state.successValue == .unstaged("a.txt"))
        #expect(try await runner.run(["diff", "--cached", "--name-only"]).stdoutString.isEmpty)
    }

    @Test("stageSelection stages only the selected lines, index byte-exact")
    func stageSelection() async throws {
        let (dir, runner) = try await makeRepo("region")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("line1\nline2\nline3\nline4\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        try Data("line1\nCHANGED2\nline3\nCHANGED4\n".utf8).write(to: dir.appendingPathComponent("f.txt"))

        let vm = AgentReviewViewModel(repoURL: dir, runner: runner)
        let diff = try await runner.run(["diff"]).stdoutString
        let lo = try #require(diff.range(of: "-line2\n")).lowerBound
        let hi = try #require(diff.range(of: "+CHANGED2\n")).upperBound
        await vm.stageSelection(in: diff, selection: lo ..< hi)

        #expect(await vm.state.successValue == .stagedSelection)
        #expect(try await runner.run(["show", ":f.txt"]).stdoutString == "line1\nCHANGED2\nline3\nline4\n")
    }

    // MARK: - Split

    @Test("split soft-resets onto the parent, leaving the commit's changes staged, and mints a snapshot")
    func splitLeavesChangesStaged() async throws {
        let (dir, runner) = try await makeRepo("split")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Seed a tracked file; the external commit changes two of its
        // lines — the classic "split one commit into two pieces" case.
        try Data("line1\nline2\nline3\nline4\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "base"])
        let parent = try await head(runner)
        try Data("line1\nCHANGED2\nline3\nCHANGED4\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "two changes"])
        let toSplit = try await head(runner)
        let preTree = try await runner.run(["rev-parse", "HEAD^{tree}"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let vm = AgentReviewViewModel(repoURL: dir, runner: runner)
        await vm.splitCommit(toSplit)

        // HEAD is now the parent; the index holds the full change (nothing lost).
        #expect(try await head(runner) == parent)
        let stagedTree = try await runner.run(["write-tree"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stagedTree == preTree) // index === the split commit's tree, byte-exact
        // The snapshot was minted at pre-split HEAD.
        let snapshot = try #require(await vm.lastSafetyCopy)
        #expect(snapshot.op == SnapshotRefName.opSplit)
        let snapSHA = try await runner.run(["rev-parse", snapshot.refName]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(snapSHA == toSplit)

        // Carve the first piece out: unstage, then region-stage only the
        // line2 change. The index now holds exactly that one line.
        _ = try await runner.run(["reset"]) // unstage all (index back to parent)
        let diff = try await runner.run(["diff"]).stdoutString
        let lo = try #require(diff.range(of: "-line2\n")).lowerBound
        let hi = try #require(diff.range(of: "+CHANGED2\n")).upperBound
        await vm.stageSelection(in: diff, selection: lo ..< hi)
        #expect(await vm.state.successValue == .stagedSelection)
        // Only line2 reached the index; line4 is still pending — the split
        // round-trips through region staging byte-exactly.
        #expect(try await runner.run(["show", ":f.txt"]).stdoutString == "line1\nCHANGED2\nline3\nline4\n")
    }

    @Test("split refuses a non-tip commit without snapshotting")
    func splitRefusesNonTip() async throws {
        let (dir, runner) = try await makeRepo("nontip")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "first"])
        let first = try await head(runner)
        try Data("2\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "second"])

        let vm = AgentReviewViewModel(repoURL: dir, runner: runner)
        await vm.splitCommit(first) // not the tip

        #expect(await vm.state.failure?.description == TaskWindowVocabulary.agentReviewSplitNotTip)
        #expect(await vm.lastSafetyCopy == nil)
        // No snapshot ref was written.
        #expect(try await runner.run(
            ["for-each-ref", SnapshotRefName.prefix], throwOnNonZero: false
        ).stdoutString.isEmpty)
    }

    @Test("split refuses when the working tree is dirty")
    func splitRefusesDirty() async throws {
        let (dir, runner) = try await makeRepo("dirty")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "base"])
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "work"])
        let tip = try await head(runner)
        // Make the tree dirty AFTER committing the splittable tip.
        try Data("dirty\n".utf8).write(to: dir.appendingPathComponent("c.txt"))

        let vm = AgentReviewViewModel(repoURL: dir, runner: runner)
        await vm.splitCommit(tip)
        #expect(await vm.state.failure?.description == TaskWindowVocabulary.agentReviewSplitDirty)
        #expect(await vm.lastSafetyCopy == nil)
    }

    // MARK: - Undo round-trip

    @Test("undo restores the pre-split HEAD SHA-exactly via the Recover path")
    func undoRoundTrip() async throws {
        let (dir, runner) = try await makeRepo("undo")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "base"])
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("x.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "splittable"])
        let preSplit = try await head(runner)

        let vm = AgentReviewViewModel(repoURL: dir, runner: runner)
        await vm.splitCommit(preSplit)
        #expect(try await head(runner) != preSplit) // soft-reset moved HEAD to parent

        await vm.undo()

        // HEAD is byte-exactly back at the pre-split commit.
        #expect(try await head(runner) == preSplit)
        #expect(await vm.state.successValue == .undone(restoredTo: preSplit))
        #expect(await vm.lastSafetyCopy == nil)
        // The working tree matches the pre-split commit exactly (clean).
        #expect(try await runner.run(["status", "--porcelain", "-z"]).stdout.isEmpty)
    }

    @Test("undo with no prior split reports nothing to undo")
    func undoNothing() async throws {
        let (dir, runner) = try await makeRepo("noundo")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "base"])

        let vm = AgentReviewViewModel(repoURL: dir, runner: runner)
        await vm.undo()
        #expect(await vm.state.failure?.description == TaskWindowVocabulary.agentReviewNothingToUndo)
    }
}
