// SnapshotIndexTests.swift
//
// Integration tests for `SnapshotIndex` against real git fixture
// repos. CLAUDE.md: "Never mock the git binary in integration tests"
// — these spawn `git init` and write snapshot refs via `git update-ref`
// directly (rather than via `SafetyKit.SnapshotWriter`, which is on a
// stacked but not-yet-merged branch). Once both slices land, a future
// PR can rewrite the helpers to go through `SnapshotWriter` for tighter
// coupling to the production write path.
//
// Helpers live in `SnapshotIndexTestSupport.swift`; pruning tests live
// in `SnapshotIndexPruneTests.swift` — split out so the test structs
// in either file stay under SwiftLint's `type_body_length` cap.

import Foundation
import GitCore
@testable import RepoState
import SafetyKit
import Testing

@Suite("SnapshotIndex — integration against real git")
struct SnapshotIndexTests {
    private typealias Support = SnapshotIndexTestSupport

    // MARK: - Lifecycle

    @Test("a fresh index has no snapshots until refreshed")
    func freshIndexIsEmpty() async throws {
        let (repo, runner) = try await Support.mkRepo("fresh")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

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
        let (repo, runner) = try await Support.mkRepo("empty")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let snapshots = await index.list()
        let lastRefresh = await index.lastRefresh
        #expect(snapshots.isEmpty)
        #expect(lastRefresh != nil, "lastRefresh should be set after refresh, even on empty repo")
    }

    // MARK: - Reads against snapshots written by raw update-ref

    @Test("refresh picks up a snapshot written via update-ref")
    func refreshSeesOneSnapshot() async throws {
        let (repo, runner) = try await Support.mkRepo("one")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        let timestamp = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)
        let written = try await Support.writeSnapshot(at: timestamp, op: SnapshotRefName.opMerge, runner: runner)

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
        let (repo, runner) = try await Support.mkRepo("order")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        let earlier = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)
        let later = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 35)

        let earlierSnap = try await Support.writeSnapshot(at: earlier, op: SnapshotRefName.opMerge, runner: runner)
        let laterSnap = try await Support.writeSnapshot(at: later, op: SnapshotRefName.opRebase, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let snapshots = await index.list()
        #expect(snapshots.count == 2)
        #expect(snapshots[0].name == laterSnap, "newest first")
        #expect(snapshots[1].name == earlierSnap)
    }

    @Test("snapshots(olderThan:) returns only entries strictly older than cutoff")
    func olderThanFilter() async throws {
        let (repo, runner) = try await Support.mkRepo("older-than")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        let early = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 0, second: 0)
        let middle = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 0, second: 30)
        let late = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 1, second: 0)

        for date in [early, middle, late] {
            try await Support.writeSnapshot(at: date, op: SnapshotRefName.opMerge, runner: runner)
        }

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let cutoff = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 0, second: 45)
        let older = await index.snapshots(olderThan: cutoff)
        // `early` and `middle` are < cutoff; `late` is > cutoff.
        #expect(older.count == 2)
        #expect(older.allSatisfy { $0.name.timestamp < cutoff })
        #expect(older.contains(where: { $0.name.timestamp == early }))
        #expect(older.contains(where: { $0.name.timestamp == middle }))
    }

    @Test("count tracks the cached list size")
    func countMatchesListSize() async throws {
        let (repo, runner) = try await Support.mkRepo("count")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        #expect(await index.count == 0)

        try await Support.writeSnapshot(
            at: Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34),
            op: SnapshotRefName.opMerge,
            runner: runner
        )
        try await index.refresh()
        #expect(await index.count == 1)
    }

    // MARK: - Defense against non-snapshot refs under the prefix

    @Test("non-snapshot refs sharing the prefix are silently skipped")
    func skipsNonSnapshotRefs() async throws {
        let (repo, runner) = try await Support.mkRepo("manual")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        // Manually create a ref under refs/sprig/snapshots/ that
        // doesn't match SnapshotRefName's shape (no `<ts>/<op>`
        // substructure — just a single segment).
        _ = try await runner.run(["update-ref", "refs/sprig/snapshots/manual-broken", "HEAD"])

        // And one well-formed snapshot for contrast.
        let valid = try await Support.writeSnapshot(
            at: Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34),
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
