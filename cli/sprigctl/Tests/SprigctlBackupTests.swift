// SprigctlBackupTests.swift
//
// `sprigctl backup` end-to-end against the built binary + real git.
// Engine semantics live in SafetyKit's WorktreeBackupTests; this
// covers the CLI contract: flag validation, --now / --list / --json
// shapes, and the fail-closed --restore round-trip.

import Foundation
import Testing

@Suite("sprigctl backup")
struct SprigctlBackupTests {
    private func makeRepo(_ label: String) async throws -> URL {
        let dir = try Sprigctl.mkRepo("backup-\(label)")
        try await Sprigctl.initRepo(at: dir)
        try Sprigctl.write("seed\n", to: dir.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: dir)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: dir)
        return dir
    }

    @Test("exactly one of --list/--now/--restore is required")
    func flagValidation() async throws {
        let dir = try await makeRepo("flags")
        defer { try? FileManager.default.removeItem(at: dir) }

        let none = try await Sprigctl.run(["backup", dir.path])
        #expect(none.exitCode != 0)
        #expect(none.stderr.contains("exactly one of"))

        let both = try await Sprigctl.run(["backup", "--list", "--now", dir.path])
        #expect(both.exitCode != 0)
    }

    @Test("--now on a clean tree reports nothing to do; dirty tree creates a ref")
    func nowCreates() async throws {
        let dir = try await makeRepo("now")
        defer { try? FileManager.default.removeItem(at: dir) }

        let clean = try await Sprigctl.run(["backup", "--now", dir.path])
        #expect(clean.exitCode == 0)
        #expect(clean.stdout.contains("nothing to back up"))

        try Sprigctl.write("dirty\n", to: dir.appendingPathComponent("a.txt"))
        let dirty = try await Sprigctl.run(["backup", "--now", dir.path])
        #expect(dirty.exitCode == 0)
        #expect(dirty.stdout.contains("backed up: refs/sprig/backup/"))
    }

    @Test("--list --json emits the documented shape")
    func listJSON() async throws {
        let dir = try await makeRepo("list")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Sprigctl.write("dirty\n", to: dir.appendingPathComponent("a.txt"))
        _ = try await Sprigctl.run(["backup", "--now", dir.path])

        let run = try await Sprigctl.run(["backup", "--list", "--json", dir.path])
        #expect(run.exitCode == 0)
        let array = try #require(
            try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [[String: Any]]
        )
        #expect(array.count == 1)
        #expect((array[0]["ref"] as? String)?.hasPrefix("refs/sprig/backup/") == true)
        #expect(array[0]["branchLabel"] as? String == "main")
    }

    @Test("--restore brings back the backed-up state and saves the pre-restore state first")
    func restoreRoundTrip() async throws {
        let dir = try await makeRepo("restore")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Sprigctl.write("precious\n", to: dir.appendingPathComponent("a.txt"))
        let created = try await Sprigctl.run(["backup", "--now", dir.path])
        let ref = try #require(
            created.stdout.split(whereSeparator: \.isWhitespace).last.map(String.init)
        )

        try Sprigctl.write("overwritten\n", to: dir.appendingPathComponent("a.txt"))
        let restored = try await Sprigctl.run(["backup", "--restore", ref, dir.path])
        #expect(restored.exitCode == 0)
        #expect(restored.stdout.contains("restored: \(ref)"))
        #expect(restored.stdout.contains("pre-restore state saved: refs/sprig/backup/"))

        let content = try String(
            contentsOf: dir.appendingPathComponent("a.txt"),
            encoding: .utf8
        ).replacingOccurrences(of: "\r\n", with: "\n")
        #expect(content == "precious\n")
    }
}
