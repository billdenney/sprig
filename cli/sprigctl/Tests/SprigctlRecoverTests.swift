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
}

private enum RecoverTestError: Error {
    case invalidSnapshotName(timestamp: Date, op: String)
}
