// SnapshotWriterTests.swift
//
// Integration tests for `SnapshotWriter` against real git fixture
// repos. CLAUDE.md: "Never mock the git binary in integration tests"
// — these spawn `git init` + `git commit` and then verify the snapshot
// ref actually lands on disk via `git rev-parse`.

import Foundation
import GitCore
@testable import SafetyKit
import Testing

@Suite("SnapshotWriter — integration against real git")
struct SnapshotWriterTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-snapshot-writer-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        return (tmp, runner)
    }

    private func seedCommit(at repo: URL, runner: Runner, named name: String = "a.txt") async throws {
        try Data("seed\n".utf8).write(to: repo.appendingPathComponent(name))
        _ = try await runner.run(["add", name])
        _ = try await runner.run(["commit", "-m", "seed"])
    }

    /// Resolve a ref to a SHA via `git rev-parse`. Returns nil if the
    /// ref doesn't exist (`rev-parse --verify --quiet` exits non-zero).
    private func revParse(_ ref: String, runner: Runner) async throws -> String? {
        let output = try await runner.run(
            ["rev-parse", "--verify", "--quiet", ref],
            throwOnNonZero: false
        )
        guard output.exitCode == 0 else { return nil }
        return output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let fixedClock: @Sendable () -> Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 6
        components.hour = 3
        components.minute = 12
        components.second = 34
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = calendar.date(from: components) ?? .distantPast
        return { date }
    }()

    @Test("createSnapshot writes a ref pointing at HEAD's commit SHA")
    func createSnapshotPointsAtHead() async throws {
        let (repo, runner) = try await mkRepo("head")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)
        let snapshot = try await writer.createSnapshot(op: SnapshotRefName.opMerge)

        #expect(snapshot.refName == "refs/sprig/snapshots/20260506T031234Z/merge")

        let snapshotSHA = try await revParse(snapshot.refName, runner: runner)
        let headSHA = try await revParse("HEAD", runner: runner)
        #expect(snapshotSHA != nil)
        #expect(snapshotSHA == headSHA)
    }

    @Test("createSnapshot accepts an explicit target SHA")
    func createSnapshotPointsAtExplicitTarget() async throws {
        let (repo, runner) = try await mkRepo("target")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        // Make a second commit so HEAD and the target differ.
        try Data("v2\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "second"])

        let firstCommitSHA = try #require(try await revParse("HEAD~1", runner: runner))
        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)
        let snapshot = try await writer.createSnapshot(
            op: SnapshotRefName.opResetHard,
            target: firstCommitSHA
        )

        let snapshotSHA = try await revParse(snapshot.refName, runner: runner)
        #expect(snapshotSHA == firstCommitSHA)
    }

    @Test("createSnapshot returns the SnapshotRefName the ref was written under")
    func returnsResolvedRefName() async throws {
        let (repo, runner) = try await mkRepo("returns")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)
        let snapshot = try await writer.createSnapshot(op: SnapshotRefName.opRebase)

        #expect(snapshot.op == SnapshotRefName.opRebase)
        #expect(snapshot.refName.hasPrefix(SnapshotRefName.prefix))
        let parsed = SnapshotRefName.parse(snapshot.refName)
        #expect(parsed == snapshot)
    }

    @Test("createSnapshot throws .invalidOp for an op that fails isValidOp")
    func rejectsInvalidOp() async throws {
        let (repo, runner) = try await mkRepo("invalid-op")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)

        await #expect(throws: SnapshotWriterError.self) {
            try await writer.createSnapshot(op: "Bad Op")
        }
        await #expect(throws: SnapshotWriterError.self) {
            try await writer.createSnapshot(op: "")
        }
    }

    @Test("createSnapshot bubbles GitError when git update-ref fails")
    func bubblesGitErrorOnInvalidTarget() async throws {
        let (repo, runner) = try await mkRepo("invalid-target")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)

        // A non-existent revspec — git update-ref exits non-zero with
        // a clear "not a valid SHA1" message; Runner translates that
        // into a GitError.nonZeroExit.
        await #expect(throws: GitError.self) {
            try await writer.createSnapshot(
                op: SnapshotRefName.opMerge,
                target: "this-ref-does-not-exist-anywhere"
            )
        }
    }

    @Test("two snapshots at distinct seconds produce distinct refs")
    func distinctTimestampsProduceDistinctRefs() async throws {
        let (repo, runner) = try await mkRepo("distinct")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        // A scripted clock that ticks one second per call.
        let counter = ScriptedClock(start: Self.fixedClock())
        let writer = SnapshotWriter(runner: runner, clock: counter.next)

        let first = try await writer.createSnapshot(op: SnapshotRefName.opMerge)
        let second = try await writer.createSnapshot(op: SnapshotRefName.opMerge)

        #expect(first.refName != second.refName)
        let firstSHA = try await revParse(first.refName, runner: runner)
        let secondSHA = try await revParse(second.refName, runner: runner)
        #expect(firstSHA != nil)
        #expect(secondSHA != nil)
        #expect(firstSHA == secondSHA, "both refs point at HEAD, so SHAs match")
    }

    @Test("same-second + same-op writes overwrite the first ref (documented limitation)")
    func sameSecondSameOpOverwrites() async throws {
        let (repo, runner) = try await mkRepo("overwrite")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        // First commit's SHA, then a second commit with a different SHA.
        let firstSHA = try #require(try await revParse("HEAD", runner: runner))
        try Data("v2\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "second"])
        let secondSHA = try #require(try await revParse("HEAD", runner: runner))
        #expect(firstSHA != secondSHA)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)
        let firstSnap = try await writer.createSnapshot(
            op: SnapshotRefName.opMerge,
            target: firstSHA
        )
        let secondSnap = try await writer.createSnapshot(
            op: SnapshotRefName.opMerge,
            target: secondSHA
        )
        #expect(firstSnap.refName == secondSnap.refName)

        // The ref now points at the second target — first snapshot lost.
        let resolved = try await revParse(firstSnap.refName, runner: runner)
        #expect(resolved == secondSHA)
    }
}

/// Tiny `@Sendable` clock that hands out monotonically-increasing
/// timestamps spaced one second apart. Internal — not enough surface
/// to justify a separate file.
private final class ScriptedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: Date

    init(start: Date) {
        self.nextValue = start
    }

    @Sendable
    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = nextValue
        nextValue = nextValue.addingTimeInterval(1)
        return value
    }
}
