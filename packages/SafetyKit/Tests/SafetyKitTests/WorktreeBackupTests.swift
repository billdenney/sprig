// WorktreeBackupTests.swift
//
// ADR 0075 against real git. The load-bearing claims under test:
// backups capture tracked + untracked state WITHOUT touching HEAD /
// index / worktree; identical dirty state across ticks doesn't mint
// twin refs; TTL pruning; and restore is fail-closed (pre-restore
// state is itself backed up).

import Foundation
import GitCore
@testable import SafetyKit
import Testing

@Suite("WorktreeBackup — create/list/prune/restore (real git)")
struct WorktreeBackupTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-backup-\(label)-\(UUID().uuidString)")
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

    /// Scripted clock: each call advances one minute so every backup
    /// gets a distinct timestamp without sleeping.
    private final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_760_000_000)

        func next() -> Date {
            lock.withLock {
                current.addTimeInterval(60)
                return current
            }
        }
    }

    private func makeBackup(_ runner: Runner) -> (WorktreeBackup, TickingClock) {
        let clock = TickingClock()
        return (WorktreeBackup(runner: runner, clock: { clock.next() }), clock)
    }

    @Test("clean tree → nil; dirty tree → a ref whose commit captures tracked + untracked")
    func createCapturesEverything() async throws {
        let (dir, runner) = try await makeRepo("create")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backup, _) = makeBackup(runner)

        #expect(try await backup.createBackupIfDirty() == nil, "clean tree backs up nothing")

        try Data("edited\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("scratch\n".utf8).write(to: dir.appendingPathComponent("untracked.txt"))
        let statusBefore = try await runner.run(["status", "--porcelain", "-z"]).stdout

        let ref = try #require(try await backup.createBackupIfDirty())
        #expect(ref.branchLabel == "main")

        // The backup commit holds BOTH changes…
        let tracked = try await runner.run(["show", "\(ref.refName):a.txt"]).stdoutString
        let untracked = try await runner.run(["show", "\(ref.refName):untracked.txt"]).stdoutString
        #expect(tracked == "edited\n")
        #expect(untracked == "scratch\n")
        // …its parent is HEAD…
        let parent = try await runner.run(["rev-parse", "\(ref.refName)^"]).stdoutString
        let head = try await runner.run(["rev-parse", "HEAD"]).stdoutString
        #expect(parent == head)
        // …and the repo state is BYTE-identical: HEAD, index, worktree.
        let statusAfter = try await runner.run(["status", "--porcelain", "-z"]).stdout
        #expect(statusAfter == statusBefore, "backup must not touch the index or worktree")
    }

    @Test("identical dirty state across ticks returns the existing ref, no twin")
    func dedupAcrossTicks() async throws {
        let (dir, runner) = try await makeRepo("dedup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backup, _) = makeBackup(runner)
        try Data("edited\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let first = try #require(try await backup.createBackupIfDirty())
        let second = try #require(try await backup.createBackupIfDirty())
        #expect(second == first, "unchanged dirty state must reuse the existing backup")
        #expect(try await backup.backups().count == 1)

        // A further edit DOES mint a new ref.
        try Data("edited again\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let third = try #require(try await backup.createBackupIfDirty())
        #expect(third != first)
        #expect(try await backup.backups().count == 2)
    }

    @Test("backups() lists newest first; prune removes only entries older than the cutoff")
    func listAndPrune() async throws {
        let (dir, runner) = try await makeRepo("prune")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backup, clock) = makeBackup(runner)

        try Data("one\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let old = try #require(try await backup.createBackupIfDirty())
        try Data("two\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let newer = try #require(try await backup.createBackupIfDirty())

        let listed = try await backup.backups()
        #expect(listed.map(\.ref) == [newer, old], "newest first")

        // Cutoff between the two: only the old one goes.
        let cutoff = old.timestamp.addingTimeInterval(30)
        let pruned = try await backup.prune(olderThan: cutoff)
        #expect(pruned == [old])
        #expect(try await backup.backups().map(\.ref) == [newer])
        _ = clock // keep alive
    }

    @Test("restore is fail-closed and additive")
    func restoreFailClosed() async throws {
        let (dir, runner) = try await makeRepo("restore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backup, _) = makeBackup(runner)

        // State A: tracked edit + untracked scratch file → backup.
        try Data("state-A\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("scratch-A\n".utf8).write(to: dir.appendingPathComponent("scratch.txt"))
        let backupA = try #require(try await backup.createBackupIfDirty())

        // Move on to state B (different content + a brand-new file).
        try Data("state-B\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("born-after-A\n".utf8).write(to: dir.appendingPathComponent("newer.txt"))

        let outcome = try await backup.restore(backupA.refName)

        // State A is back…
        let a = try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let scratch = try String(contentsOf: dir.appendingPathComponent("scratch.txt"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        #expect(a == "state-A\n")
        #expect(scratch == "scratch-A\n")
        // …additively (files born after A survive)…
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("newer.txt").path))
        // …and state B was saved first (fail-closed), restorable too.
        let preRestore = try #require(outcome.preRestoreBackup)
        let bContent = try await runner.run(["show", "\(preRestore.refName):a.txt"]).stdoutString
        #expect(bContent == "state-B\n")
    }

    @Test("unborn-HEAD repo (no commits) still backs up, with no parent")
    func unbornHead() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-backup-unborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        try Data("first ever work\n".utf8).write(to: dir.appendingPathComponent("draft.txt"))

        let (backup, _) = makeBackup(runner)
        let ref = try #require(try await backup.createBackupIfDirty())

        let content = try await runner.run(["show", "\(ref.refName):draft.txt"]).stdoutString
        #expect(content == "first ever work\n")
        let parentProbe = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "\(ref.refName)^"],
            throwOnNonZero: false
        )
        #expect(parentProbe.exitCode != 0, "no parent on an unborn branch")
    }

    @Test("same-second backups of different states get distinct refs — restore source survives")
    func sameSecondCollisionAvoided() async throws {
        let (dir, runner) = try await makeRepo("collision")
        defer { try? FileManager.default.removeItem(at: dir) }
        // FROZEN clock: every backup wants the same timestamp — the
        // exact shape of restore's fail-closed pre-backup landing in
        // the same second as the backup being restored.
        let frozen = Date(timeIntervalSince1970: 1_760_000_000)
        let backup = WorktreeBackup(runner: runner, clock: { frozen })

        try Data("precious\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let first = try #require(try await backup.createBackupIfDirty())
        try Data("overwritten\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let outcome = try await backup.restore(first.refName)

        // The pre-restore backup minted a DISTINCT ref (+1 s), and the
        // restored content is the original — not the clobbered tree.
        let pre = try #require(outcome.preRestoreBackup)
        #expect(pre != first)
        #expect(try await backup.backups().count == 2)
        let restored = try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        #expect(restored == "precious\n")
    }

    @Test("same-second backup whose base ref is already taken advances atomically — neither clobbered")
    func sameSecondBaseRefTakenAdvancesWithoutClobber() async throws {
        let (dir, runner) = try await makeRepo("atomic-create")
        defer { try? FileManager.default.removeItem(at: dir) }
        // FROZEN clock: the new backup wants exactly the second another
        // writer already occupies.
        let frozen = Date(timeIntervalSince1970: 1_760_000_000)
        let backup = WorktreeBackup(runner: runner, clock: { frozen })

        // Stand in for a concurrent writer (the agent's auto-backup, or a
        // restore's fail-closed pre-backup) that already took THIS
        // second's base ref pointing at HEAD — the residual TOCTOU the
        // atomic `create` closes: with the old probe-then-write the
        // second writer could find the name vacant and blind-overwrite
        // the first. Pre-creating the ref forces the `create` to lose,
        // deterministically, the way it would lose the lock under a real
        // race.
        let headSHA = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseRef = "refs/sprig/backup/\(SnapshotRefName.formatTimestamp(frozen))/main"
        _ = try await runner.run(["update-ref", baseRef, headSHA])

        // A genuinely different dirty tree now wants a backup this same
        // second.
        try Data("precious\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let ref = try #require(try await backup.createBackupIfDirty())

        // The new backup advanced to the +1 s slot…
        let bumped = "refs/sprig/backup/\(SnapshotRefName.formatTimestamp(frozen.addingTimeInterval(1)))/main"
        #expect(ref.refName == bumped)
        // …the already-taken base ref is byte-preserved (NOT overwritten
        // with the new commit)…
        let baseAfter = try await runner.run(["rev-parse", baseRef]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(baseAfter == headSHA, "the already-taken base ref must not be clobbered")
        // …and both refs coexist, the new one carrying the precious tree.
        let all = try await backup.backups()
        #expect(all.count == 2, "both the pre-existing backup and the new one survive")
        let newEntry = try #require(all.first { $0.ref == ref })
        #expect(try await runner.run(["show", "\(newEntry.sha):a.txt"]).stdoutString == "precious\n")
    }

    @Test("junk files (secrets + temporaries) are excluded from the backup tree at any depth")
    func junkFilesExcluded() async throws {
        let (dir, runner) = try await makeRepo("denylist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backup, _) = makeBackup(runner)

        // Legit dirty state…
        try Data("edited\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("keep me\n".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        // …plus junk that must NOT persist into git objects: secrets
        // at the root and nested, and tool temporaries.
        try Data("AWS_KEY=x\n".utf8).write(to: dir.appendingPathComponent("prod.env"))
        let nested = dir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("token\n".utf8).write(to: nested.appendingPathComponent("service.pem"))
        try Data("lock\n".utf8).write(to: dir.appendingPathComponent("~$Budget.xlsx"))
        try Data("scratch\n".utf8).write(to: dir.appendingPathComponent("x.tmp"))

        let ref = try #require(try await backup.createBackupIfDirty())
        let lsTree = try await runner.run(["ls-tree", "-r", "--name-only", ref.refName])
        let paths = Set(lsTree.stdoutString.split(whereSeparator: \.isNewline).map(String.init))

        #expect(paths.contains("a.txt"))
        #expect(paths.contains("notes.txt"))
        #expect(!paths.contains("prod.env"), "secrets must not enter backup objects")
        #expect(!paths.contains("config/service.pem"), "exclusion must reach nested dirs")
        #expect(!paths.contains("~$Budget.xlsx"))
        #expect(!paths.contains("x.tmp"))
    }

    @Test("a tree dirty ONLY with junk files backs up nothing")
    func junkOnlyDirtyIsClean() async throws {
        let (dir, runner) = try await makeRepo("junk-only")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backup, _) = makeBackup(runner)

        try Data("AWS_KEY=x\n".utf8).write(to: dir.appendingPathComponent(".env.local"))
        try Data("lock\n".utf8).write(to: dir.appendingPathComponent("~$Doc.docx"))

        #expect(
            try await backup.createBackupIfDirty() == nil,
            "status is dirty, but the excluded tree equals HEAD — no ref"
        )
        #expect(try await backup.backups().isEmpty)
    }

    @Test("custom excludedPatterns replace the defaults")
    func customExcludePatterns() async throws {
        let (dir, runner) = try await makeRepo("custom-excl")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Narrow deny-list: only *.scratch. The default junk rules
        // are replaced, so a .env DOES get captured here.
        let clock = TickingClock()
        let backup = WorktreeBackup(
            runner: runner,
            clock: { clock.next() },
            excludedPatterns: ["**/*.scratch"]
        )

        try Data("keep\n".utf8).write(to: dir.appendingPathComponent("prod.env"))
        try Data("drop\n".utf8).write(to: dir.appendingPathComponent("work.scratch"))

        let ref = try #require(try await backup.createBackupIfDirty())
        let lsTree = try await runner.run(["ls-tree", "-r", "--name-only", ref.refName])
        let paths = Set(lsTree.stdoutString.split(whereSeparator: \.isNewline).map(String.init))
        #expect(paths.contains("prod.env"))
        #expect(!paths.contains("work.scratch"))
    }

    @Test("BackupRefName: sanitization, round-trip parse, foreign-ref rejection")
    func refNameContract() {
        let ts = Date(timeIntervalSince1970: 1_760_000_000)
        let ref = BackupRefName(timestamp: ts, branchLabel: "feature/x y")
        #expect(ref?.branchLabel == "feature-x-y")
        if let ref {
            #expect(BackupRefName.parse(ref.refName) == ref)
        }
        #expect(BackupRefName.parse("refs/sprig/snapshots/20260101T000000Z/merge") == nil)
        #expect(BackupRefName.parse("refs/sprig/backup/not-a-ts/main") == nil)
        #expect(BackupRefName.parse("refs/sprig/backup/20260101T000000Z") == nil)
    }
}
