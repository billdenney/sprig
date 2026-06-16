// StackRestackViewModelTests.swift
//
// ADR 0085 against real git. The load-bearing claims:
//
//   - the safety copy is minted at the child's pre-restack tip and
//     restoring it through the Recover surface returns the branch
//     exactly — the full restack → undo round-trip;
//   - restacking a non-current branch refuses (the undo resets the
//     current branch, so it must be the one being restacked);
//   - a conflicted restack is the worded handoff with the rebase left
//     parked (and no branch switch);
//   - refusals are worded and mint NO snapshot.

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

// `.serialized`: real-git fixtures with ref writes per test.
@Suite("StackRestackViewModel — stacked restack (real git)", .serialized)
struct StackRestackViewModelTests {
    /// Bare origin + pushed stack main ← feature-a (a1,a2) ←
    /// feature-b (b1,b2), links recorded. Leaves HEAD on feature-b.
    private func makeStack(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-restackvm-\(label)-\(UUID().uuidString)").standardized
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
        for (from, br, files) in [("main", "feature-a", ["a1", "a2"]), ("feature-a", "feature-b", ["b1", "b2"])] {
            _ = try await runner.run(["switch", "-c", br, from])
            for name in files {
                try Data("\(name)\n".utf8).write(to: work.appendingPathComponent("\(name).txt"))
                _ = try await runner.run(["add", "\(name).txt"])
                _ = try await runner.run(["commit", "-m", name])
            }
            _ = try await runner.run(["push", "-u", "origin", br])
        }
        let stacks = StackOps(runner: runner)
        try await stacks.recordStackLink(child: "feature-a", parent: "main")
        try await stacks.recordStackLink(child: "feature-b", parent: "feature-a")
        return (dir, runner)
    }

    private func sha(_ runner: Runner, _ rev: String) async throws -> String {
        try await runner.run(["rev-parse", rev])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("restack mints the safety copy at the pre-restack tip; Recover undoes it")
    func restackAndRecoverRoundTrip() async throws {
        let (dir, runner) = try await makeStack("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        // Move the parent, then restack from ON feature-b (so the
        // Recover reset path targets feature-b directly).
        _ = try await runner.run(["switch", "feature-a"])
        try Data("a3\n".utf8).write(to: work.appendingPathComponent("a3.txt"))
        _ = try await runner.run(["add", "a3.txt"])
        _ = try await runner.run(["commit", "-m", "a3"])
        _ = try await runner.run(["switch", "feature-b"])
        let before = try await sha(runner, "feature-b")

        let vm = StackRestackViewModel(repoURL: dir, runner: runner)
        await vm.restack(branch: "feature-b")

        guard case .success = await vm.state else {
            await Issue.record("expected .success, got \(vm.state)")
            return
        }
        let safetyCopy = try #require(await vm.lastSafetyCopy)
        #expect(safetyCopy.op == SnapshotRefName.opRestack)
        #expect(try await sha(runner, safetyCopy.refName) == before, "snapshot pins the pre-restack tip")
        #expect(try await sha(runner, "feature-b") != before, "feature-b actually moved")

        // The undo: Recover's reset path on the (restored-to) feature-b.
        let recover = RecoverViewModel(repoURL: dir, runner: runner)
        await recover.restoreSnapshot(safetyCopy.refName)
        #expect(try await sha(runner, "feature-b") == before, "restore returns feature-b to its exact pre-restack tip")
    }

    @Test("restacking a non-current branch refuses (the undo would reset the wrong branch); no snapshot")
    func refusesNonCurrentBranch() async throws {
        let (dir, runner) = try await makeStack("notcurrent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        _ = try await runner.run(["switch", "feature-a"])
        try Data("a3\n".utf8).write(to: work.appendingPathComponent("a3.txt"))
        _ = try await runner.run(["add", "a3.txt"])
        _ = try await runner.run(["commit", "-m", "a3"])
        let featureBBefore = try await sha(runner, "feature-b")
        // User is on feature-a and asks to restack the non-current
        // child feature-b.
        let vm = StackRestackViewModel(repoURL: dir, runner: runner)

        await vm.restack(branch: "feature-b")

        guard case let .failure(failure) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(failure.description == TaskWindowVocabulary.restackNotCheckedOut)
        #expect(await vm.lastSafetyCopy == nil, "a refusal mints no snapshot")
        #expect(try await sha(runner, "feature-b") == featureBBefore, "feature-b untouched")
        let current = try await runner.run(["symbolic-ref", "--short", "HEAD"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(current == "feature-a", "HEAD untouched")
    }

    @Test("a conflicted restack is the worded handoff with the rebase left parked")
    func conflictHandoff() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-restackvm-conflict-\(UUID().uuidString)").standardized
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
        _ = try await runner.run(["switch", "-c", "feature-a"])
        try Data("a\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "a1"])
        _ = try await runner.run(["switch", "-c", "feature-b"])
        try Data("from-b\n".utf8).write(to: work.appendingPathComponent("conflict.txt"))
        _ = try await runner.run(["commit", "-am", "b-conflict"])
        try await StackOps(runner: runner).recordStackLink(child: "feature-b", parent: "feature-a")
        _ = try await runner.run(["switch", "feature-a"])
        try Data("from-a\n".utf8).write(to: work.appendingPathComponent("conflict.txt"))
        _ = try await runner.run(["commit", "-am", "a-conflict"])
        // Restack the CHECKED-OUT child (the VM refuses a non-current one).
        _ = try await runner.run(["switch", "feature-b"])

        let vm = StackRestackViewModel(repoURL: dir, runner: runner)
        await vm.restack(branch: "feature-b")

        guard case let .failure(failure) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(failure.description == TaskWindowVocabulary.rebaseConflictHandoff)
        #expect(await vm.conflictedPathCount == 1)
        let abort = try await runner.run(["rebase", "--abort"], throwOnNonZero: false)
        #expect(abort.exitCode == 0, "the rebase must be left parked for the resolver")
    }

    @Test("refusals are worded and mint no snapshot")
    func refusalsWorded() async throws {
        let (dir, runner) = try await makeStack("refuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        // Unlinked branch → worded refusal, no snapshot.
        _ = try await runner.run(["switch", "-c", "loner", "main"])
        try Data("l\n".utf8).write(to: work.appendingPathComponent("l.txt"))
        _ = try await runner.run(["add", "l.txt"])
        _ = try await runner.run(["commit", "-m", "l"])

        let vm = StackRestackViewModel(repoURL: dir, runner: runner)
        await vm.restack(branch: "loner")

        guard case let .failure(failure) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(failure.description == TaskWindowVocabulary.restackNoParentRecorded)
        #expect(await vm.lastSafetyCopy == nil, "a refusal mints no snapshot")
    }
}
