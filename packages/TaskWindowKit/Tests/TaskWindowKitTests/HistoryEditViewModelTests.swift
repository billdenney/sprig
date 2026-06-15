// HistoryEditViewModelTests.swift
//
// ADR 0082 against real git. The load-bearing claims:
//
//   - the safety copy is minted BEFORE the rewrite, at the pre-edit
//     HEAD, and restoring it through the Recover surface brings the
//     old tip back — the full edit → undo round-trip;
//   - VM pre-guards (empty message, count bounds, nothing unpushed)
//     are worded validation failures that spawn no rewrite;
//   - unpushedCount bounds the squash from the VM's own refresh, so
//     the shared-history refusal fires before any snapshot exists.

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

// `.serialized`: real-git fixtures with ref writes per test; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("HistoryEditViewModel — reword + squash (real git)", .serialized)
struct HistoryEditViewModelTests {
    /// Repo with a bare `origin`, one PUSHED seed commit, and two
    /// local-only commits ("wip 1", "wip 2").
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-historyvm-\(label)-\(UUID().uuidString)")
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
        for (file, message) in [("b.txt", "wip 1"), ("c.txt", "wip 2")] {
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

    @Test("refresh reports the rewritable depth and HEAD's subject")
    func refreshCounts() async throws {
        let (dir, runner) = try await makeRepo("refresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = HistoryEditViewModel(repoURL: dir, runner: runner)

        await vm.refresh()

        #expect(await vm.unpushedCount == 2)
        #expect(await vm.lastSubject == "wip 2")
    }

    @Test("reword mints the safety copy at the pre-edit tip, then rewrites the message")
    func rewordWithSafetyCopy() async throws {
        let (dir, runner) = try await makeRepo("reword")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = HistoryEditViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let before = try await headSHA(runner)

        await vm.reword(message: "feat: wip 2, properly worded")

        guard case let .success(newSHA) = await vm.state else {
            await Issue.record("expected .success, got \(vm.state)")
            return
        }
        #expect(newSHA != before)
        let safetyCopy = try #require(await vm.lastSafetyCopy)
        #expect(safetyCopy.op == SnapshotRefName.opReword)
        let pinned = try await runner.run(["rev-parse", safetyCopy.refName])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pinned == before, "safety copy must point at the pre-edit tip")
        #expect(await vm.lastSubject == "feat: wip 2, properly worded")
    }

    @Test("squash succeeds and the Recover surface's restore undoes it — full round-trip")
    func squashAndRecoverRoundTrip() async throws {
        let (dir, runner) = try await makeRepo("squashundo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = HistoryEditViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let before = try await headSHA(runner)

        await vm.squash(count: 2, message: "feat: both wips")

        guard case .success = await vm.state else {
            await Issue.record("expected .success, got \(vm.state)")
            return
        }
        #expect(await vm.unpushedCount == 1, "two wips became one commit")
        let safetyCopy = try #require(await vm.lastSafetyCopy)
        #expect(safetyCopy.op == SnapshotRefName.opSquash)

        // The undo: standard Recover reset path back to the old tip.
        let recover = RecoverViewModel(repoURL: dir, runner: runner)
        await recover.restoreSnapshot(safetyCopy.refName)
        #expect(try await headSHA(runner) == before, "restore must bring the pre-squash tip back")
        await vm.refresh()
        #expect(await vm.unpushedCount == 2)
        #expect(await vm.lastSubject == "wip 2")
    }

    @Test("VM pre-guards word the failure and spawn no rewrite")
    func preGuardsAreWordedValidation() async throws {
        let (dir, runner) = try await makeRepo("preguards")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = HistoryEditViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let before = try await headSHA(runner)

        await vm.reword(message: "   ")
        guard case let .failure(emptyMessage) = await vm.state else {
            Issue.record("expected .failure for empty message")
            return
        }
        #expect(emptyMessage.description == TaskWindowVocabulary.enterCommitSubject)

        await vm.squash(count: 1, message: "m")
        guard case let .failure(needTwo) = await vm.state else {
            Issue.record("expected .failure for count 1")
            return
        }
        #expect(needTwo.description == TaskWindowVocabulary.historyNeedTwo)

        await vm.squash(count: 3, message: "m")
        guard case let .failure(shared) = await vm.state else {
            Issue.record("expected .failure for count beyond unpushed depth")
            return
        }
        #expect(shared.description == TaskWindowVocabulary.historyShared)

        #expect(try await headSHA(runner) == before, "no pre-guard may touch the repo")
        #expect(await vm.lastSafetyCopy == nil, "no snapshot before validation passes")
    }

    @Test("revert succeeds with the safety copy at the pre-revert tip; Recover undoes it")
    func revertAndRecoverRoundTrip() async throws {
        let (dir, runner) = try await makeRepo("revert")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = HistoryEditViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let wip1SHA = try await runner.run(["rev-parse", "HEAD~1"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = try await headSHA(runner)

        await vm.revert(sha: wip1SHA)

        guard case let .success(newSHA) = await vm.state else {
            await Issue.record("expected .success, got \(vm.state)")
            return
        }
        #expect(newSHA != before)
        let safetyCopy = try #require(await vm.lastSafetyCopy)
        #expect(safetyCopy.op == SnapshotRefName.opRevert)
        let pinned = try await runner.run(["rev-parse", safetyCopy.refName])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pinned == before, "safety copy must point at the pre-revert tip")
        let work = dir.appendingPathComponent("work")
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("b.txt").path))

        // The undo: standard Recover reset path — the revert commit
        // is gone and wip 1's file is back.
        let recover = RecoverViewModel(repoURL: dir, runner: runner)
        await recover.restoreSnapshot(safetyCopy.refName)
        #expect(try await headSHA(runner) == before)
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("b.txt").path))
    }

    @Test("revert refusals are worded: merge commit, unknown commit")
    func revertRefusalsWorded() async throws {
        let (dir, runner) = try await makeRepo("revertrefuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = HistoryEditViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        await vm.revert(sha: "0123456789abcdef0123456789abcdef01234567")
        guard case let .failure(unknown) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(unknown.description == TaskWindowVocabulary.revertUnknownCommit)
    }

    @Test("everything pushed: reword refuses as shared before any snapshot exists")
    func nothingUnpushedRefusesEarly() async throws {
        let (dir, runner) = try await makeRepo("allpushed")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await runner.run(["push", "origin", "main"])
        let vm = HistoryEditViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        #expect(await vm.unpushedCount == 0)

        await vm.reword(message: "rewrite pushed history")

        guard case let .failure(failure) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(failure.description == TaskWindowVocabulary.historyShared)
        #expect(await vm.lastSafetyCopy == nil)
    }
}
