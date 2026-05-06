// SnapshotIndexTests.swift
//
// Integration tests for `SnapshotIndex` against real git fixture
// repos. CLAUDE.md: "Never mock the git binary in integration tests"
// — these spawn `git init` and write snapshot refs via `git update-ref`
// directly (rather than via `SafetyKit.SnapshotWriter`, which is on a
// stacked but not-yet-merged branch). Once both slices land, a future
// PR can rewrite the helpers to go through `SnapshotWriter` for tighter
// coupling to the production write path.

import Foundation
import GitCore
@testable import RepoState
import SafetyKit
import Testing

@Suite("SnapshotIndex — integration against real git")
struct SnapshotIndexTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-snapshot-index-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        return (tmp, runner)
    }

    private func seedCommit(at repo: URL, runner: Runner) async throws {
        try Data("seed\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
    }

    /// Write a snapshot ref via `git update-ref` directly. Mirrors what
    /// `SafetyKit.SnapshotWriter` will do when its slice merges; using
    /// the raw form here keeps S3's branch independent of S2's.
    @discardableResult
    private func writeSnapshot(
        at timestamp: Date,
        op: String,
        runner: Runner,
        target: String = "HEAD"
    ) async throws -> SnapshotRefName {
        guard let name = SnapshotRefName(timestamp: timestamp, op: op) else {
            throw SnapshotIndexTestError.invalidRefName(timestamp: timestamp, op: op)
        }
        _ = try await runner.run(["update-ref", name.refName, target])
        return name
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
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

    // MARK: - Lifecycle

    @Test("a fresh index has no snapshots until refreshed")
    func freshIndexIsEmpty() async throws {
        let (repo, runner) = try await mkRepo("fresh")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let index = SnapshotIndex(runner: runner)
        let initial = await index.list()
        let initialCount = await index.count
        let initialRefresh = await index.lastRefresh
        #expect(initial.isEmpty)
        #expect(initialCount == 0)
        #expect(initialRefresh == nil)
    }

    @Test("refresh on a repo with no snapshots yields an empty list")
    func refreshOnEmptyRepoIsEmpty() async throws {
        let (repo, runner) = try await mkRepo("empty")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let snapshots = await index.list()
        let lastRefresh = await index.lastRefresh
        #expect(snapshots.isEmpty)
        #expect(lastRefresh != nil, "lastRefresh should be set after refresh, even on empty repo")
    }

    // MARK: - Reads against snapshots written by SnapshotWriter

    @Test("refresh picks up a snapshot written via update-ref")
    func refreshSeesOneSnapshot() async throws {
        let (repo, runner) = try await mkRepo("one")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let timestamp = Self.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)
        let written = try await writeSnapshot(at: timestamp, op: SnapshotRefName.opMerge, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let snapshots = await index.list()
        #expect(snapshots.count == 1)
        let first = try #require(snapshots.first)
        #expect(first.name == written)
        // SHA should be 40 chars (SHA-1) or 64 (SHA-256) — git's choice.
        #expect(first.sha.count == 40 || first.sha.count == 64)
    }

    @Test("refresh returns snapshots newest-first")
    func newestFirstOrdering() async throws {
        let (repo, runner) = try await mkRepo("order")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let earlier = Self.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)
        let later = Self.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 35)

        let earlierSnap = try await writeSnapshot(at: earlier, op: SnapshotRefName.opMerge, runner: runner)
        let laterSnap = try await writeSnapshot(at: later, op: SnapshotRefName.opRebase, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let snapshots = await index.list()
        #expect(snapshots.count == 2)
        #expect(snapshots[0].name == laterSnap, "newest first")
        #expect(snapshots[1].name == earlierSnap)
    }

    @Test("snapshots(olderThan:) returns only entries strictly older than cutoff")
    func olderThanFilter() async throws {
        let (repo, runner) = try await mkRepo("older-than")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let early = Self.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 0, second: 0)
        let middle = Self.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 0, second: 30)
        let late = Self.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 1, second: 0)

        for date in [early, middle, late] {
            try await writeSnapshot(at: date, op: SnapshotRefName.opMerge, runner: runner)
        }

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let cutoff = Self.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 0, second: 45)
        let older = await index.snapshots(olderThan: cutoff)
        // `early` and `middle` are < cutoff; `late` is > cutoff.
        #expect(older.count == 2)
        #expect(older.allSatisfy { $0.name.timestamp < cutoff })
        #expect(older.contains(where: { $0.name.timestamp == early }))
        #expect(older.contains(where: { $0.name.timestamp == middle }))
    }

    @Test("count tracks the cached list size")
    func countMatchesListSize() async throws {
        let (repo, runner) = try await mkRepo("count")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        #expect(await index.count == 0)

        try await writeSnapshot(
            at: Self.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34),
            op: SnapshotRefName.opMerge,
            runner: runner
        )
        try await index.refresh()
        #expect(await index.count == 1)
    }

    // MARK: - Defense against non-snapshot refs under the prefix

    @Test("non-snapshot refs sharing the prefix are silently skipped")
    func skipsNonSnapshotRefs() async throws {
        let (repo, runner) = try await mkRepo("manual")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        // Manually create a ref under refs/sprig/snapshots/ that
        // doesn't match SnapshotRefName's shape (no `<ts>/<op>`
        // substructure — just a single segment).
        _ = try await runner.run(["update-ref", "refs/sprig/snapshots/manual-broken", "HEAD"])

        // And one well-formed snapshot for contrast.
        let valid = try await writeSnapshot(
            at: Self.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34),
            op: SnapshotRefName.opMerge,
            runner: runner
        )

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let snapshots = await index.list()
        #expect(snapshots.count == 1, "only the valid snapshot should appear")
        #expect(snapshots.first?.name == valid)
    }

    // MARK: - Pure parser

    @Test("parse handles standard for-each-ref output")
    func parseStandardOutput() {
        let stdout = """
        refs/sprig/snapshots/20260506T031234Z/merge abc123def4567890abc123def4567890abc12345
        refs/sprig/snapshots/20260506T031300Z/rebase 123abc4567890abc123def4567890abc12345def
        """
        let parsed = SnapshotIndex.parse(stdout)
        #expect(parsed.count == 2)
        #expect(parsed[0].name.op == SnapshotRefName.opMerge)
        #expect(parsed[0].sha == "abc123def4567890abc123def4567890abc12345")
        #expect(parsed[1].name.op == SnapshotRefName.opRebase)
    }

    @Test("parse skips lines that don't have two fields")
    func parseSkipsMalformedLines() {
        let stdout = """
        refs/sprig/snapshots/20260506T031234Z/merge abc123def4567890abc123def4567890abc12345
        no_space_here
        """
        let parsed = SnapshotIndex.parse(stdout)
        #expect(parsed.count == 1)
    }

    @Test("parse skips lines whose first field doesn't parse as a SnapshotRefName")
    func parseSkipsNonSnapshots() {
        let stdout = """
        refs/heads/main abc123def4567890abc123def4567890abc12345
        refs/sprig/snapshots/20260506T031234Z/merge def4567890abc123def4567890abc12345abc123
        """
        let parsed = SnapshotIndex.parse(stdout)
        #expect(parsed.count == 1)
        #expect(parsed[0].name.op == SnapshotRefName.opMerge)
    }
}

private enum SnapshotIndexTestError: Error {
    case invalidRefName(timestamp: Date, op: String)
}
