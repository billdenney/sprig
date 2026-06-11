import Foundation
import IPCSchema
import SafetyKit
import Testing

// `sprigctl recover --list` end-to-end CLI tests. Lives in its own file
// (split from `SprigctlTests.swift`) so neither file trips SwiftLint's
// `file_length` cap as the recover surface grows. Test helpers (the
// `Sprigctl` namespace enum) are still in `SprigctlSupport.swift`.

@Suite("sprigctl recover")
struct SprigctlRecoverTests {
    @Test("recover --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["recover", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.lowercased().contains("recover"))
        #expect(out.stdout.contains("--list"))
    }

    @Test("recover without --list errors with a helpful message")
    func errorsWithoutMode() async throws {
        let repo = try Sprigctl.mkRepo("recover-no-mode")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)

        let out = try await Sprigctl.run(["recover", repo.path])
        #expect(out.exitCode != 0)
        // ArgumentParser prints validation errors to stderr.
        #expect(out.stderr.contains("--list") || out.stderr.contains("--restore"))
    }

    @Test("recover --list on a repo with no snapshots prints nothing on stdout")
    func emptyRepo() async throws {
        let repo = try Sprigctl.mkRepo("recover-empty")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)

        let out = try await Sprigctl.run(["recover", "--list", repo.path])
        #expect(out.exitCode == 0)
        // No snapshots → empty stdout.
        #expect(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // The "no snapshots" diagnostic goes to stderr.
        #expect(out.stderr.contains("no snapshots"))
    }

    @Test("recover --list shows snapshot refs in human-readable form")
    func humanList() async throws {
        let repo = try Sprigctl.mkRepo("recover-human")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)

        let timestamp = utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)
        try await writeSnapshot(at: timestamp, op: SnapshotRefName.opMerge, in: repo)

        let out = try await Sprigctl.run(["recover", "--list", repo.path])
        #expect(out.exitCode == 0)
        // Human format: ISO-8601 timestamp, op, short SHA, full ref.
        #expect(out.stdout.contains("merge"))
        #expect(out.stdout.contains("refs/sprig/snapshots/20260506T031234Z/merge"))
        #expect(out.stdout.contains("2026-05-06"))
    }

    @Test("recover --list and --restore are mutually exclusive")
    func mutuallyExclusiveFlags() async throws {
        let repo = try Sprigctl.mkRepo("recover-mutex")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)

        let out = try await Sprigctl.run([
            "recover",
            "--list",
            "--restore", "refs/sprig/snapshots/20260506T031234Z/merge",
            repo.path
        ])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("mutually exclusive"))
    }

    // MARK: - --restore

    @Test("restore rejects refs that don't parse as snapshot refs")
    func restoreRejectsBadFormat() async throws {
        let repo = try Sprigctl.mkRepo("recover-bad-format")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)

        // A perfectly valid git ref, but not a snapshot ref.
        let out = try await Sprigctl.run([
            "recover",
            "--restore", "refs/heads/main",
            repo.path
        ])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("snapshot format"))
    }

    @Test("restore errors when the snapshot ref doesn't exist")
    func restoreRejectsNonexistentRef() async throws {
        let repo = try Sprigctl.mkRepo("recover-nonexistent")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)

        let phantom = "refs/sprig/snapshots/20260506T031234Z/merge"
        let out = try await Sprigctl.run([
            "recover",
            "--restore", phantom,
            repo.path
        ])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("does not exist"))
    }

    @Test("restore moves HEAD to the snapshot's commit and creates a before-snapshot")
    func restoreResetsHEAD() async throws {
        let repo = try Sprigctl.mkRepo("recover-restore")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)

        // Snapshot the seed commit, then make a second commit so HEAD
        // diverges from the snapshot.
        let timestamp = utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)
        try await writeSnapshot(at: timestamp, op: SnapshotRefName.opMerge, in: repo)
        let snapshotRef = "refs/sprig/snapshots/20260506T031234Z/merge"

        try Sprigctl.write("v2\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["commit", "-am", "second"], cwd: repo)

        let beforeRestoreHEAD = try await readHEAD(in: repo)
        let snapshotSHA = try await readRefSHA(snapshotRef, in: repo)
        #expect(beforeRestoreHEAD != snapshotSHA, "HEAD should differ from the snapshot before restore")

        let out = try await Sprigctl.run([
            "recover",
            "--restore", snapshotRef,
            repo.path
        ])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Restored worktree to \(snapshotRef)"))
        #expect(out.stdout.contains("Before-restore snapshot:"))

        // HEAD now matches the snapshot.
        let afterRestoreHEAD = try await readHEAD(in: repo)
        #expect(afterRestoreHEAD == snapshotSHA)

        // A new "restore" snapshot exists that captures the
        // pre-restore HEAD; we don't know its exact name (timestamp
        // is `Date()`), but `for-each-ref` should find one.
        let listOut = try await Sprigctl.run(["recover", "--list", "--json", repo.path])
        let trimmed = listOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let array = try #require(parsed as? [[String: Any]])
        let beforeSnap = array.first { $0["op"] as? String == "restore" }
        let beforeSnapDict = try #require(beforeSnap)
        #expect(beforeSnapDict["sha"] as? String == beforeRestoreHEAD)
    }

    @Test("restore is reversible — restoring the before-snapshot brings HEAD back")
    func restoreIsReversible() async throws {
        let repo = try Sprigctl.mkRepo("recover-reversible")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)

        let firstSeedHEAD = try await readHEAD(in: repo)

        // Snapshot the seed, then add a second commit.
        let timestamp = utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)
        try await writeSnapshot(at: timestamp, op: SnapshotRefName.opMerge, in: repo)
        let snapshotRef = "refs/sprig/snapshots/20260506T031234Z/merge"

        try Sprigctl.write("v2\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["commit", "-am", "second"], cwd: repo)
        let preRestoreHEAD = try await readHEAD(in: repo)

        // First restore: HEAD → first commit.
        _ = try await Sprigctl.run(["recover", "--restore", snapshotRef, repo.path])
        #expect(try await readHEAD(in: repo) == firstSeedHEAD)

        // Find the before-restore snapshot.
        let listOut = try await Sprigctl.run(["recover", "--list", "--json", repo.path])
        let trimmed = listOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let array = try #require(parsed as? [[String: Any]])
        let beforeSnap = try #require(array.first { $0["op"] as? String == "restore" })
        let beforeSnapRef = try #require(beforeSnap["refName"] as? String)

        // Sleep > 1 s so the second restore's own before-snapshot has
        // a distinct timestamp and doesn't overwrite the first one's
        // before-snapshot (`SnapshotWriter`'s same-second-same-op
        // collision behavior, documented in PR #60). Without this
        // delay, `git update-ref refs/.../restore` would move
        // `beforeSnapRef` to the new HEAD before the `git reset
        // --hard` reads it, and we'd end up back where we started.
        try await Task.sleep(for: .seconds(1.2))

        // Second restore: HEAD back to second commit via the before-snapshot.
        _ = try await Sprigctl.run(["recover", "--restore", beforeSnapRef, repo.path])
        #expect(try await readHEAD(in: repo) == preRestoreHEAD)
    }

    @Test("recover --list --json emits a sorted-keys JSON array")
    func jsonList() async throws {
        let repo = try Sprigctl.mkRepo("recover-json")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)

        let early = utcDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        let late = utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)
        try await writeSnapshot(at: early, op: SnapshotRefName.opRebase, in: repo)
        try await writeSnapshot(at: late, op: SnapshotRefName.opMerge, in: repo)

        let out = try await Sprigctl.run(["recover", "--list", "--json", repo.path])
        #expect(out.exitCode == 0)

        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let array = try #require(parsed as? [[String: Any]])
        #expect(array.count == 2)
        // Newest first per `SnapshotIndex.list()`'s contract — the late
        // (May 6) entry sorts before the early (Jan 1) entry.
        #expect(array[0]["op"] as? String == SnapshotRefName.opMerge)
        #expect(array[1]["op"] as? String == SnapshotRefName.opRebase)
        // Each entry has the four wire-format keys, all string-typed.
        for entry in array {
            #expect(entry["refName"] is String)
            #expect(entry["op"] is String)
            #expect(entry["timestamp"] is String)
            #expect(entry["sha"] is String)
        }
    }

    @Test("restore on a dirty tree saves uncommitted work into a backup ref first")
    func restoreSavesUncommittedWork() async throws {
        let repo = try Sprigctl.mkRepo("recover-dirty-restore")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)
        try await writeSnapshot(
            at: utcDate(year: 2026, month: 1, day: 1),
            op: SnapshotRefName.opMerge,
            in: repo
        )
        // Dirty the tree AFTER the snapshot: a tracked edit the hard
        // reset would otherwise eat.
        try Sprigctl.write("precious uncommitted\n", to: repo.appendingPathComponent("a.txt"))

        let out = try await Sprigctl.run([
            "recover",
            "--restore", "refs/sprig/snapshots/20260101T000000Z/merge",
            repo.path
        ])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Uncommitted work saved: refs/sprig/backup/"))

        // The advertised backup ref really contains the dirty content.
        let backupRef = try #require(
            out.stdout.split(whereSeparator: \.isNewline)
                .first { $0.hasPrefix("Uncommitted work saved: ") }?
                .replacingOccurrences(of: "Uncommitted work saved: ", with: "")
        )
        let shown = try await Sprigctl.run([
            "backup", "--list", "--json", repo.path
        ])
        // Parse rather than substring-match: JSONEncoder escapes "/"
        // in string values.
        let object = try JSONSerialization.jsonObject(with: Data(shown.stdout.utf8))
        let array = try #require(object as? [[String: Any]])
        #expect(
            array.contains { ($0["ref"] as? String) == backupRef },
            "backup ref must be listed"
        )
    }

    // MARK: - Helpers

    /// Create a one-commit repo so HEAD resolves and snapshots can
    /// point somewhere.
    private func seed(repo: URL) async throws {
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)
    }

    /// Write a snapshot ref via raw `git update-ref`. Mirrors
    /// `SafetyKit.SnapshotWriter` but doesn't require importing
    /// `GitCore.Runner` here — keeps this test file dependency-light.
    private func writeSnapshot(at timestamp: Date, op: String, in repo: URL) async throws {
        guard let name = SnapshotRefName(timestamp: timestamp, op: op) else {
            throw RecoverTestError.invalidSnapshotName(timestamp: timestamp, op: op)
        }
        try await Sprigctl.spawnGit(["update-ref", name.refName, "HEAD"], cwd: repo)
    }

    private func utcDate(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components) ?? .distantPast
    }

    /// Read HEAD's commit SHA via `git rev-parse HEAD`. Returns the
    /// full hex SHA, trimmed of whitespace.
    private func readHEAD(in repo: URL) async throws -> String {
        try await readRefSHA("HEAD", in: repo)
    }

    /// Read the commit SHA a ref points at via `git rev-parse <ref>`.
    private func readRefSHA(_ ref: String, in repo: URL) async throws -> String {
        let process = Process()
        process.executableURL = try URL(fileURLWithPath: Sprigctl.gitBinaryPath())
        process.arguments = ["rev-parse", ref]
        process.currentDirectoryURL = repo
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// ADR 0079 — the stash-aware restore path.
extension SprigctlRecoverTests {
    @Test("restore of a stash-drop safety copy puts the entry back in the stash list")
    func restoreStashDropStoresEntry() async throws {
        let repo = try Sprigctl.mkRepo("recover-stashdrop")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)

        // The ADR 0079 dropKeepingSafetyCopy sequence, spelled in raw
        // git: stash an edit, snapshot the stash COMMIT, drop it.
        try Sprigctl.write("wip\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["stash", "push", "-m", "wip work"], cwd: repo)
        let stashSHA = try await readRefSHA("refs/stash", in: repo)
        let snapshotRef = "refs/sprig/snapshots/20260506T040000Z/stash-drop"
        try await Sprigctl.spawnGit(["update-ref", snapshotRef, stashSHA], cwd: repo)
        try await Sprigctl.spawnGit(["stash", "drop"], cwd: repo)
        let headBefore = try await readHEAD(in: repo)

        let out = try await Sprigctl.run([
            "recover",
            "--restore", snapshotRef,
            repo.path
        ])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Restored stash entry from \(snapshotRef)"))
        #expect(out.stdout.contains("stash@{0}"))

        // The entry is back under its original identity; HEAD never
        // moved (a stash-drop restore must not reset the worktree).
        let restoredSHA = try await readRefSHA("refs/stash", in: repo)
        #expect(restoredSHA == stashSHA)
        let headAfter = try await readHEAD(in: repo)
        #expect(headAfter == headBefore)
    }
}

private enum RecoverTestError: Error {
    case invalidSnapshotName(timestamp: Date, op: String)
}
