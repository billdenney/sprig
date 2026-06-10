// RecoverViewModelTests.swift
//
// ADR 0033 amendment against real git: ONE list of everything
// restorable, with restores that are themselves undoable. The
// load-bearing claims:
//
//   - the list merges both ref namespaces newest-first;
//   - restoring a snapshot NEVER eats uncommitted work (it goes into
//     an ADR 0075 backup first) and is undoable via the
//     before-restore snapshot — proven by a full round-trip;
//   - restoring a backup is additive and fail-closed (engine
//     contract, re-asserted at this layer);
//   - non-Sprig refs are rejected before any git runs.

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

// `.serialized`: real-git fixtures with ref writes per test; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("RecoverViewModel — unified recovery surface (real git)", .serialized)
struct RecoverViewModelTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-recover-\(label)-\(UUID().uuidString)")
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

    private func head(_ runner: Runner) async throws -> String {
        try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("refresh() merges snapshots and backups newest-first with the right kinds")
    func refreshMergesNamespaces() async throws {
        let (dir, runner) = try await makeRepo("list")
        defer { try? FileManager.default.removeItem(at: dir) }

        // A snapshot at an older timestamp, a backup at a newer one —
        // scripted clocks so the ordering claim is deterministic.
        let older = Date(timeIntervalSince1970: 1_760_000_000)
        let newer = older.addingTimeInterval(600)
        let snapshot = try await SnapshotWriter(runner: runner, clock: { older })
            .createSnapshot(op: SnapshotRefName.opMerge)
        try Data("dirty\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let backup = try #require(
            try await WorktreeBackup(runner: runner, clock: { newer }).createBackupIfDirty()
        )

        let vm = RecoverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let points = await vm.points
        #expect(await vm.state == .success(.refreshed(pointCount: 2)))
        #expect(points.map(\.refName) == [backup.refName, snapshot.refName], "newest first")
        #expect(points[0].kind == .backup(branchLabel: "main"))
        #expect(points[1].kind == .snapshot(op: SnapshotRefName.opMerge))
        #expect(points[0].timestamp == newer)
    }

    @Test("restoreSnapshot: uncommitted work is backed up, the reset lands, and the restore round-trips")
    func restoreSnapshotIsInsuredAndUndoable() async throws {
        let (dir, runner) = try await makeRepo("snapshot-restore")
        defer { try? FileManager.default.removeItem(at: dir) }

        // HEAD₀ (seed) gets a snapshot; HEAD₁ moves on; the tree gets
        // dirty (tracked edit + untracked scratch).
        let head0 = try await head(runner)
        let snapshot = try await SnapshotWriter(runner: runner)
            .createSnapshot(op: SnapshotRefName.opResetHard)
        try Data("second\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "b.txt"])
        _ = try await runner.run(["commit", "-m", "second"])
        let head1 = try await head(runner)
        try Data("precious edit\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("precious scratch\n".utf8).write(to: dir.appendingPathComponent("wip.txt"))

        let vm = RecoverViewModel(repoURL: dir, runner: runner)
        await vm.restoreSnapshot(snapshot.refName)

        // The reset landed at HEAD₀…
        #expect(try await head(runner) == head0)
        guard case let .success(.restoredSnapshot(restoredRef, beforeRestore, uncommitted)) =
            await vm.state
        else {
            await Issue.record("expected restoredSnapshot, got \(vm.state)")
            return
        }
        #expect(restoredRef == snapshot.refName)
        // …the before-restore snapshot points at HEAD₁…
        let beforeSHA = try await runner.run(["rev-parse", beforeRestore.refName]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(beforeSHA == head1)
        // …and BOTH dirty files are recoverable from the backup.
        let backupRef = try #require(uncommitted, "dirty tree must be captured")
        let edit = try await runner.run(["show", "\(backupRef.refName):a.txt"]).stdoutString
        let scratch = try await runner.run(["show", "\(backupRef.refName):wip.txt"]).stdoutString
        #expect(edit == "precious edit\n")
        #expect(scratch == "precious scratch\n")
        // The list refreshed without clobbering the outcome the UI shows.
        #expect(await !vm.points.isEmpty)

        // Round-trip: restoring the before-restore snapshot undoes it.
        await vm.restoreSnapshot(beforeRestore.refName)
        #expect(try await head(runner) == head1)
    }

    @Test("restoreBackup: additive, fail-closed, and reported with the pre-restore ref")
    func restoreBackupJourney() async throws {
        let (dir, runner) = try await makeRepo("backup-restore")
        defer { try? FileManager.default.removeItem(at: dir) }

        // State A backed up; tree moves on to state B.
        try Data("state-A\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let ticking = Date(timeIntervalSince1970: 1_760_000_000)
        let backupA = try #require(
            try await WorktreeBackup(runner: runner, clock: { ticking }).createBackupIfDirty()
        )
        try Data("state-B\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let vm = RecoverViewModel(repoURL: dir, runner: runner)
        await vm.restoreBackup(backupA.refName)

        guard case let .success(.restoredBackup(outcome)) = await vm.state else {
            await Issue.record("expected restoredBackup, got \(vm.state)")
            return
        }
        #expect(outcome.restoredFrom == backupA)
        #expect(outcome.preRestoreBackup != nil, "state B was saved first (fail-closed)")
        let restored = try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        #expect(restored == "state-A\n")
    }

    @Test("non-Sprig refs are rejected before any git runs; missing refs report cleanly")
    func preconditionRejections() async throws {
        let (dir, runner) = try await makeRepo("rejects")
        defer { try? FileManager.default.removeItem(at: dir) }
        let preHEAD = try await head(runner)
        let vm = RecoverViewModel(repoURL: dir, runner: runner)

        await vm.restoreSnapshot("refs/heads/main")
        #expect(
            await vm.state.failure?.description
                == TaskWindowVocabulary.notASnapshotRef("refs/heads/main")
        )

        await vm.restoreBackup("refs/heads/main")
        #expect(
            await vm.state.failure?.description
                == TaskWindowVocabulary.notABackupRef("refs/heads/main")
        )

        // Valid format, but the ref was never written.
        let ghost = "refs/sprig/snapshots/20260101T000000Z/merge"
        await vm.restoreSnapshot(ghost)
        #expect(
            await vm.state.failure?.description
                == TaskWindowVocabulary.recoveryRefMissing(ghost)
        )

        #expect(try await head(runner) == preHEAD, "rejections must not move the repo")
    }
}
