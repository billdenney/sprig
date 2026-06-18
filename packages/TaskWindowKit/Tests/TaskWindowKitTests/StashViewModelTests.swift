// StashViewModelTests.swift
//
// ADR 0079 against real git. The load-bearing claims:
//
//   - verbs re-resolve entries by commit SHA, so a list gone stale
//     behind the VM's back (indices shifted by an outside drop) still
//     acts on the RIGHT entry — and a vanished entry is a worded
//     failure, never a misfire;
//   - dropKeepingSafetyCopy writes the ADR 0033 medium-tier snapshot
//     at the stash COMMIT before dropping, and the Recover surface's
//     stash-aware restore puts the entry back in the list — the full
//     drop → undo round-trip;
//   - apply keeps the entry; pop removes exactly the popped one.

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

// `.serialized`: real-git fixtures with ref writes per test; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("StashViewModel — stash browser (real git)", .serialized)
struct StashViewModelTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-stashvm-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        // Git for Windows defaults core.autocrlf=true (system config),
        // which rewrites text files to CRLF whenever git touches the
        // worktree (stash push's reset, apply, pop) — pin it off so
        // the byte-exact content assertions below hold on every OS.
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    /// Two stash entries on `a.txt`: "first" (older, listed second)
    /// then "second" (newer, listed first). Tree is clean afterwards.
    private func seedTwoStashes(_ dir: URL, _ runner: Runner) async throws {
        let stash = StashOps(runner: runner)
        try Data("first edit\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await stash.push(message: "first")
        try Data("second edit\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await stash.push(message: "second")
    }

    private func fileContent(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
    }

    @Test("refresh lists entries newest first")
    func refreshPopulates() async throws {
        let (dir, runner) = try await makeRepo("refresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let vm = StashViewModel(repoURL: dir, runner: runner)

        await vm.refresh()

        let entries = await vm.entries
        #expect(entries.map(\.subject) == ["On main: second", "On main: first"])
        guard case .success = await vm.state else {
            await Issue.record("expected .success, got \(vm.state)")
            return
        }
    }

    @Test("apply restores the files and keeps the entry listed")
    func applyKeepsEntry() async throws {
        let (dir, runner) = try await makeRepo("apply")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let vm = StashViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let older = try #require(await vm.entries.last)

        await vm.apply(older)

        #expect(await vm.state == .success("On main: first"))
        let applied = try fileContent(dir)
        #expect(applied == "first edit\n")
        #expect(await vm.entries.count == 2)
    }

    @Test("pop applies an entry and removes exactly it from the list")
    func popRemovesEntry() async throws {
        let (dir, runner) = try await makeRepo("pop")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let vm = StashViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let older = try #require(await vm.entries.last)

        await vm.pop(older)

        #expect(await vm.state == .success("On main: first"))
        let popped = try fileContent(dir)
        #expect(popped == "first edit\n")
        #expect(await vm.entries.map(\.subject) == ["On main: second"])
    }

    @Test("drop writes the safety copy at the stash commit; Recover puts the entry back")
    func dropAndRecoverRoundTrip() async throws {
        let (dir, runner) = try await makeRepo("droproundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let vm = StashViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let victim = try #require(await vm.entries.first)

        await vm.dropKeepingSafetyCopy(victim)

        #expect(await vm.state == .success("On main: second"))
        #expect(await vm.entries.map(\.subject) == ["On main: first"])
        let safetyCopy = try #require(await vm.lastSafetyCopy)
        #expect(safetyCopy.op == SnapshotRefName.opStashDrop)
        let pinned = try await runner.run(["rev-parse", safetyCopy.refName])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pinned == victim.sha, "safety copy must point at the dropped stash commit")

        // The undo: Recover's stash-aware restore — entry back in the
        // list with its identity (SHA + subject) intact, worktree and
        // HEAD untouched.
        let headBefore = try await runner.run(["rev-parse", "HEAD"]).stdoutString
        let recover = RecoverViewModel(repoURL: dir, runner: runner)
        await recover.restoreSnapshot(safetyCopy.refName)

        #expect(await recover.state == .success(.restoredStashEntry(refName: safetyCopy.refName)))
        await vm.refresh()
        let restored = try #require(await vm.entries.first)
        #expect(restored.sha == victim.sha)
        #expect(restored.subject == "On main: second")
        let headAfter = try await runner.run(["rev-parse", "HEAD"]).stdoutString
        #expect(headBefore == headAfter, "stash-drop restore must not move HEAD")
    }

    @Test("Recover routes a uniquified stash-drop-2 safety copy to stash-store, not reset --hard")
    func recoverUniquifiedStashDropStoresEntry() async throws {
        let (dir, runner) = try await makeRepo("stashdrop2")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)

        // The stash COMMIT a same-second second drop would snapshot,
        // minted under the `-2` uniquifier. (StashViewModel's writer uses
        // the wall clock and can't be forced into a same-second collision
        // from here, so mint the ref directly — the exact shape
        // createSnapshot produces on a same-second same-op collision.)
        let victimSHA = try await runner.run(["rev-parse", "refs/stash"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = "refs/sprig/snapshots/20260506T040000Z/stash-drop-2"
        _ = try await runner.run(["update-ref", ref, victimSHA])
        _ = try await runner.run(["stash", "drop"])
        let headBefore = try await runner.run(["rev-parse", "HEAD"]).stdoutString

        let recover = RecoverViewModel(repoURL: dir, runner: runner)
        await recover.restoreSnapshot(ref)

        // Must take the stash-store path (HEAD untouched), NOT `reset
        // --hard` onto the stash commit — the bug the op-suffix uniquifier
        // would otherwise expose through the exact-string op match.
        #expect(await recover.state == .success(.restoredStashEntry(refName: ref)))
        let restoredSHA = try await runner.run(["rev-parse", "refs/stash"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(restoredSHA == victimSHA)
        let headAfter = try await runner.run(["rev-parse", "HEAD"]).stdoutString
        #expect(headBefore == headAfter, "a stash-drop restore must never move HEAD")
    }

    @Test("a list gone stale behind the VM's back still acts on the RIGHT entry")
    func staleIndicesStillResolveBySHA() async throws {
        let (dir, runner) = try await makeRepo("stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let vm = StashViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        // Hold "first" while it is stash@{1}…
        let held = try #require(await vm.entries.last)
        #expect(held.ref == "stash@{1}")
        // …then shift the indices behind the VM's back: dropping
        // stash@{0} makes the held entry stash@{0}.
        _ = try await runner.run(["stash", "drop", "stash@{0}"])

        await vm.pop(held)

        #expect(await vm.state == .success("On main: first"))
        let heldContent = try fileContent(dir)
        #expect(heldContent == "first edit\n", "must pop the held entry, not the selector")
        #expect(await vm.entries.isEmpty)
    }

    @Test("acting on a vanished entry is a worded failure, and the list self-corrects")
    func vanishedEntryFailsClosed() async throws {
        let (dir, runner) = try await makeRepo("vanished")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let vm = StashViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let newest = try #require(await vm.entries.first)
        _ = try await runner.run(["stash", "drop", "stash@{0}"])

        await vm.apply(newest)

        guard case let .failure(failure) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(failure.description == TaskWindowVocabulary.stashEntryGone("On main: second"))
        #expect(await vm.entries.map(\.subject) == ["On main: first"])
        let untouched = try fileContent(dir)
        #expect(untouched == "seed\n", "nothing may be applied on a vanished entry")
    }

    @Test("conflicted apply is worded, keeps the copy, and the files show the conflict")
    func conflictedApplyWorded() async throws {
        let (dir, runner) = try await makeRepo("conflict")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stash = StashOps(runner: runner)
        try Data("stashed line\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await stash.push(message: "conflicting work")
        try Data("committed line\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "diverge"])
        let vm = StashViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let entry = try #require(await vm.entries.first)

        await vm.apply(entry)

        guard case let .failure(failure) = await vm.state else {
            await Issue.record("expected .failure, got \(vm.state)")
            return
        }
        #expect(
            failure.description
                == TaskWindowVocabulary.stashConflicted("On main: conflicting work")
        )
        #expect(await vm.entries.count == 1, "the set-aside copy must survive a conflicted apply")
    }
}
