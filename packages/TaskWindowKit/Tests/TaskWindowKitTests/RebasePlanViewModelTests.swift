// RebasePlanViewModelTests.swift
//
// ADR 0083 against real git. The load-bearing claims:
//
//   - the safety copy is minted at the pre-plan tip BEFORE anything
//     replays, and a COMPLETED plan restores through Recover's
//     standard reset path — the full plan → undo round-trip;
//   - a conflicted replay is the worded handoff to the Conflicts
//     surface, with the parked rebase left for it (and the path
//     count exposed for the banner);
//   - an empty rewritable range is a worded validation failure that
//     mints no snapshot.

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

// `.serialized`: real-git fixtures with ref writes per test; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("RebasePlanViewModel — plan-driven rebase (real git)", .serialized)
struct RebasePlanViewModelTests {
    /// Repo with a bare `origin`, one PUSHED seed, and three
    /// local-only commits B, C, D.
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-rebasevm-\(label)-\(UUID().uuidString)")
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

    private func headSHA(_ runner: Runner) async throws -> String {
        try await runner.run(["rev-parse", "HEAD"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("a completed plan restores through Recover — the full round-trip")
    func planAndRecoverRoundTrip() async throws {
        let (dir, runner) = try await makeRepo("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = RebasePlanViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let commits = await vm.commits
        #expect(commits.map(\.subject) == ["B", "C", "D"])
        let before = try await headSHA(runner)

        await vm.apply([
            RebaseStep(.pick, commits[2].sha),
            RebaseStep(.pick, commits[0].sha),
            RebaseStep(.drop, commits[1].sha)
        ])

        guard case .success = await vm.state else {
            await Issue.record("expected .success, got \(vm.state)")
            return
        }
        #expect(await vm.commits.map(\.subject) == ["D", "B"])
        let safetyCopy = try #require(await vm.lastSafetyCopy)
        #expect(safetyCopy.op == SnapshotRefName.opRebase)
        let pinned = try await runner.run(["rev-parse", safetyCopy.refName])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pinned == before, "safety copy must point at the pre-plan tip")

        let recover = RecoverViewModel(repoURL: dir, runner: runner)
        await recover.restoreSnapshot(safetyCopy.refName)
        #expect(try await headSHA(runner) == before, "restore must bring the pre-plan tip back")
        await vm.refresh()
        #expect(await vm.commits.map(\.subject) == ["B", "C", "D"])
    }

    @Test("a conflicted replay is the worded handoff, with the parked rebase left in place")
    func conflictHandoffWorded() async throws {
        let (dir, runner) = try await makeRepo("conflict")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        try Data("from-E\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "E"])
        try Data("from-F\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "F"])
        let vm = RebasePlanViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let commits = await vm.commits
        var reordered = commits.map { RebaseStep(.pick, $0.sha) }
        reordered.swapAt(3, 4) // E and F trade places — cannot replay cleanly

        await vm.apply(reordered)

        guard case let .failure(failure) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(failure.description == TaskWindowVocabulary.rebaseConflictHandoff)
        #expect(await vm.conflictedPathCount == 1)
        // A successful abort proves the rebase was genuinely parked
        // for the resolver (it errors when nothing is in progress).
        let abort = try await runner.run(["rebase", "--abort"], throwOnNonZero: false)
        #expect(abort.exitCode == 0, "a parked rebase must be present for the resolver")
    }

    @Test("an empty rewritable range is worded validation; no snapshot is minted")
    func emptyRangeWorded() async throws {
        let (dir, runner) = try await makeRepo("empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await runner.run(["push", "origin", "main"])
        let vm = RebasePlanViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        #expect(await vm.commits.isEmpty)

        await vm.apply([])

        guard case let .failure(failure) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(failure.description == TaskWindowVocabulary.nothingToRebase)
        #expect(await vm.lastSafetyCopy == nil)
    }

    @Test("an invalid plan is worded generically")
    func invalidPlanWorded() async throws {
        let (dir, runner) = try await makeRepo("invalid")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = RebasePlanViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let commits = await vm.commits

        await vm.apply([RebaseStep(.pick, commits[0].sha)])

        guard case let .failure(failure) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(failure.description == TaskWindowVocabulary.invalidRebasePlan)
    }
}
