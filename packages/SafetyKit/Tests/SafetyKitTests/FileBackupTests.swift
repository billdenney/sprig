// FileBackupTests.swift
//
// ADR 0090 — the single-file safety backup, against real git. The
// load-bearing claims: a backup captures the file's current bytes into a
// gc-safe ref, restore is fail-closed (backs up current bytes first) and
// round-trips byte-for-byte, same-second backups don't clobber each
// other, and refs are scoped per file path.

import Foundation
import GitCore
@testable import SafetyKit
import Testing

@Suite("FileBackup — single-file safety backup (real git)", .serialized)
struct FileBackupTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-filebackup-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        try Data("committed\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "f.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    private func content(_ dir: URL, _ relative: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("backupFile captures the file's current bytes; restore round-trips byte-for-byte")
    func backupAndRestoreRoundTrips() async throws {
        let (dir, runner) = try await makeRepo("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("current bytes\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        let backup = FileBackup(runner: runner)

        let ref = try #require(try await backup.backupFile(at: "f.txt"))
        // Overwrite with an "old version", then restore the backup.
        try Data("an older version\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        let outcome = try await backup.restore(ref.refName, to: "f.txt")

        #expect(try content(dir, "f.txt") == "current bytes\n")
        // Fail-closed: restoring backed up the pre-restore ("old") bytes.
        let pre = try #require(outcome.preRestoreBackup)
        let preBytes = try await runner.run(["cat-file", "blob", pre.refName]).stdoutString
        #expect(preBytes == "an older version\n")
    }

    @Test("backupFile returns nil when the file does not exist")
    func backupMissingFileIsNil() async throws {
        let (dir, runner) = try await makeRepo("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = try await FileBackup(runner: runner).backupFile(at: "nope.txt")
        #expect(made == nil)
    }

    @Test("two same-second backups of one file both survive (timestamp bump)")
    func sameSecondBackupsBothSurvive() async throws {
        let (dir, runner) = try await makeRepo("samesecond")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixed = Date(timeIntervalSince1970: 1_780_000_000)
        let backup = FileBackup(runner: runner, clock: { fixed })

        try Data("A\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        let first = try #require(try await backup.backupFile(at: "f.txt"))
        try Data("B\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        let second = try #require(try await backup.backupFile(at: "f.txt"))

        #expect(first.refName != second.refName) // bumped one second, no clobber
        let firstBytes = try await runner.run(["cat-file", "blob", first.refName]).stdoutString
        let secondBytes = try await runner.run(["cat-file", "blob", second.refName]).stdoutString
        #expect(firstBytes == "A\n")
        #expect(secondBytes == "B\n")
    }

    @Test("backups(for:) lists only the requested file, newest first")
    func backupsScopedToPath() async throws {
        let (dir, runner) = try await makeRepo("scoped")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("g\n".utf8).write(to: dir.appendingPathComponent("g.txt"))
        let backup = FileBackup(runner: runner)
        _ = try await backup.backupFile(at: "f.txt")
        _ = try await backup.backupFile(at: "g.txt")

        let forF = try await backup.backups(for: "f.txt")
        #expect(forF.count == 1)
        #expect(forF.first?.ref.label == "f%2Etxt")
    }

    @Test("paths differing only in separators get distinct labels (no cross-contamination)")
    func separatorPathsDontCollide() async throws {
        let (dir, runner) = try await makeRepo("collide")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("a"), withIntermediateDirectories: true
        )
        try Data("slash\n".utf8).write(to: dir.appendingPathComponent("a/b"))
        try Data("dash\n".utf8).write(to: dir.appendingPathComponent("a-b"))
        let backup = FileBackup(runner: runner)
        _ = try await backup.backupFile(at: "a/b")
        _ = try await backup.backupFile(at: "a-b")

        #expect(try await backup.backups(for: "a/b").count == 1)
        #expect(try await backup.backups(for: "a-b").count == 1)
    }

    @Test("backupFile refuses a symlink path rather than following it out of the repo")
    func refusesSymlink() async throws {
        let (dir, runner) = try await makeRepo("symlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.txt"),
            withDestinationURL: dir.appendingPathComponent("f.txt")
        )
        await #expect(throws: FileBackupError.refusedSymlink("link.txt")) {
            _ = try await FileBackup(runner: runner).backupFile(at: "link.txt")
        }
    }

    @Test("FileBackupRefName sanitizes paths (valid + injective) and round-trips through parse")
    func refNameSanitizeAndParse() throws {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let ref = try #require(FileBackupRefName(timestamp: date, filePath: "src/main.swift"))
        // '/' and '.' percent-encoded → a valid, injective ref segment.
        #expect(ref.label == "src%2Fmain%2Eswift")
        #expect(ref.refName.hasPrefix("refs/sprig/filebackup/"))
        let parsed = try #require(FileBackupRefName.parse(ref.refName))
        #expect(parsed == ref)
        #expect(FileBackupRefName.parse("refs/heads/main") == nil)
        // A dotfile path produces a valid ref (leading '.' would be rejected).
        let dotfile = try #require(FileBackupRefName(timestamp: date, filePath: ".gitignore"))
        #expect(dotfile.label == "%2Egitignore")
    }
}
