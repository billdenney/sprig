// SnapshotIndexPruneTests.swift
//
// Tests for `SnapshotIndex.prune(olderThan:)` — the engine half of
// ADR 0033's TTL pruner. Split out from `SnapshotIndexTests.swift` so
// neither struct trips SwiftLint's `type_body_length` cap as the
// SnapshotIndex surface grows. Helpers come from
// `SnapshotIndexTestSupport.swift`.

import Foundation
import GitCore
@testable import RepoState
import SafetyKit
import Testing

@Suite("SnapshotIndex.prune — integration against real git")
struct SnapshotIndexPruneTests {
    private typealias Support = SnapshotIndexTestSupport

    @Test("prune on an empty cache returns an empty result")
    func pruneOnEmptyCacheReturnsEmpty() async throws {
        let (repo, runner) = try await Support.mkRepo("prune-empty")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let pruned = try await index.prune(olderThan: Date())
        #expect(pruned.isEmpty)
        #expect(await index.count == 0)
    }

    @Test("prune is a no-op when no cached snapshot is older than cutoff")
    func pruneNoOpWhenNothingIsOldEnough() async throws {
        let (repo, runner) = try await Support.mkRepo("prune-noop")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        let timestamp = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)
        try await Support.writeSnapshot(at: timestamp, op: SnapshotRefName.opMerge, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        // Cutoff predates every snapshot in the cache.
        let cutoff = Support.utcDate(year: 2026, month: 1, day: 1)
        let pruned = try await index.prune(olderThan: cutoff)
        #expect(pruned.isEmpty)
        #expect(await index.count == 1)
    }

    @Test("prune removes only snapshots older than cutoff and refreshes the cache")
    func prunesOlderRefsOnly() async throws {
        let (repo, runner) = try await Support.mkRepo("prune-mixed")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        let early = Support.utcDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        let middle = Support.utcDate(year: 2026, month: 3, day: 1, hour: 0, minute: 0, second: 0)
        let late = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)

        try await Support.writeSnapshot(at: early, op: SnapshotRefName.opMerge, runner: runner)
        try await Support.writeSnapshot(at: middle, op: SnapshotRefName.opRebase, runner: runner)
        try await Support.writeSnapshot(at: late, op: SnapshotRefName.opForcePush, runner: runner)

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        #expect(await index.count == 3)

        // Cutoff is Feb 1 — only `early` (Jan 1) is strictly older.
        let cutoff = Support.utcDate(year: 2026, month: 2, day: 1)
        let pruned = try await index.prune(olderThan: cutoff)
        #expect(pruned.count == 1)
        #expect(pruned.first?.name.timestamp == early)
        #expect(pruned.first?.name.op == SnapshotRefName.opMerge)

        // Cache reflects the deletion.
        let remaining = await index.list()
        #expect(remaining.count == 2)
        #expect(remaining.contains(where: { $0.name.timestamp == late }))
        #expect(remaining.contains(where: { $0.name.timestamp == middle }))
        #expect(!remaining.contains(where: { $0.name.timestamp == early }))

        // And the underlying repo no longer has the deleted ref.
        let prunedName = try #require(pruned.first?.name.refName)
        let revParse = try await runner.run(
            ["rev-parse", "--verify", "--quiet", prunedName],
            throwOnNonZero: false
        )
        #expect(revParse.exitCode != 0, "the pruned ref should no longer resolve via git")
    }

    @Test("prune deletes every cached snapshot when cutoff is in the future")
    func prunesEverythingWhenCutoffIsFuture() async throws {
        let (repo, runner) = try await Support.mkRepo("prune-all")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Support.seedCommit(at: repo, runner: runner)

        for second in 30 ... 33 {
            let timestamp = Support.utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: second)
            try await Support.writeSnapshot(at: timestamp, op: "auto-prune-\(second)", runner: runner)
        }

        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        #expect(await index.count == 4)

        // Cutoff far in the future — every snapshot is "older."
        let cutoff = Support.utcDate(year: 2099, month: 1, day: 1)
        let pruned = try await index.prune(olderThan: cutoff)
        #expect(pruned.count == 4)
        #expect(await index.list().isEmpty)
    }
}
