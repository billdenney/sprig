// WithSnapshotTests.swift
//
// Integration tests for `SnapshotWriter.withSnapshot(...)` — slice S4 of
// ADR 0033. Same fixture pattern as `SnapshotWriterTests`: spawn real
// `git init` + `git commit`, run the helper, verify the snapshot ref
// actually lands on disk via `git rev-parse`. CLAUDE.md hard rule: do
// not mock the git binary in integration tests.

import Foundation
import GitCore
@testable import SafetyKit
import Testing

@Suite("SnapshotWriter.withSnapshot — integration against real git")
struct WithSnapshotTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-with-snapshot-\(tag)-\(UUID().uuidString)")
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

    @Test("withSnapshot creates a ref before body runs and returns body's value on success")
    func snapshotThenSuccessReturnsBodyResult() async throws {
        let (repo, runner) = try await mkRepo("success")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)
        let headBefore = try #require(try await revParse("HEAD", runner: runner))

        let result: String = try await writer.withSnapshot(op: SnapshotRefName.opMerge) { snapshot in
            // The ref MUST exist by the time body runs.
            let resolved = try await self.revParse(snapshot.refName, runner: runner)
            #expect(resolved == headBefore, "snapshot must be written before body executes")
            return "body-return-value"
        }

        #expect(result == "body-return-value")
    }

    @Test("withSnapshot rethrows body's error but the snapshot persists for recovery")
    func snapshotPersistsWhenBodyThrows() async throws {
        let (repo, runner) = try await mkRepo("body-throws")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)
        let headBefore = try #require(try await revParse("HEAD", runner: runner))

        struct BodyError: Error, Equatable { let tag: String }

        await #expect(throws: BodyError(tag: "boom")) {
            try await writer.withSnapshot(op: SnapshotRefName.opResetHard) { _ in
                throw BodyError(tag: "boom")
            }
        }

        // The snapshot ref is still on disk even though body threw.
        // This is the entire safety contract: the ref outlives body's
        // outcome so the caller can recover via SnapshotIndex.
        let expectedRef = "refs/sprig/snapshots/20260506T031234Z/reset-hard"
        let resolved = try await revParse(expectedRef, runner: runner)
        #expect(resolved == headBefore, "snapshot ref must survive body throw")
    }

    @Test("withSnapshot invokes body exactly once on success and zero times on snapshot failure")
    func bodyInvocationCount() async throws {
        let (repo, runner) = try await mkRepo("invocation-count")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)

        // Success path — body runs once.
        let calls = Counter()
        _ = try await writer.withSnapshot(op: SnapshotRefName.opMerge) { _ in
            await calls.increment()
        }
        #expect(await calls.value == 1)

        // Snapshot-creation failure (invalid op) — body never runs.
        let calls2 = Counter()
        await #expect(throws: SnapshotWriterError.self) {
            try await writer.withSnapshot(op: "Bad Op") { _ in
                await calls2.increment()
            }
        }
        #expect(await calls2.value == 0)
    }

    @Test("withSnapshot snapshots HEAD by default; explicit target overrides")
    func explicitTargetOverridesHead() async throws {
        let (repo, runner) = try await mkRepo("target-override")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        // Make a second commit so HEAD and the parent differ.
        try Data("v2\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "second"])
        let parentSHA = try #require(try await revParse("HEAD~1", runner: runner))
        let headSHA = try #require(try await revParse("HEAD", runner: runner))
        #expect(parentSHA != headSHA)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)
        try await writer.withSnapshot(
            op: SnapshotRefName.opResetHard,
            target: parentSHA
        ) { snapshot in
            let resolved = try await self.revParse(snapshot.refName, runner: runner)
            #expect(resolved == parentSHA, "snapshot points at the explicit target, not HEAD")
        }
    }

    @Test("withSnapshot returns @discardableResult — caller can ignore the value")
    func discardableResultCompiles() async throws {
        let (repo, runner) = try await mkRepo("discardable")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seedCommit(at: repo, runner: runner)

        let writer = SnapshotWriter(runner: runner, clock: Self.fixedClock)

        // No `let _ = ...` needed; @discardableResult means this compiles cleanly.
        try await writer.withSnapshot(op: SnapshotRefName.opMerge) { _ in
            "ignored"
        }
    }
}

/// Tiny actor counter for the invocation-count assertion. Inline rather
/// than shared because no other test wants this shape today.
private actor Counter {
    private(set) var value: Int = 0
    func increment() {
        value += 1
    }
}
