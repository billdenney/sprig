// StashOpsBrowseTests.swift
//
// ADR 0079 by-ref stash verbs against real git (never mocked). The
// contracts under test: list's NUL-delimited parse (selector / SHA /
// date / subject, newest first), apply keeps the entry, pop targets a
// SPECIFIC entry and drops exactly it, drop returns the SHA a safety
// copy needs, and unresolvable selectors throw instead of misfiring.

import Foundation
@testable import GitCore
import Testing

@Suite("StashOps — browse verbs (list/apply/pop/drop by ref) against real git")
struct StashOpsBrowseTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-stashbrowse-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        // Git for Windows defaults core.autocrlf=true (system config),
        // which rewrites text files to CRLF whenever git touches the
        // worktree (stash push's reset, apply, pop) — pin it off so
        // the byte-exact content assertions below hold on every OS.
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    /// Two stash entries on `a.txt`: "first" (older, `stash@{1}`)
    /// then "second" (newer, `stash@{0}`). Tree is clean afterwards.
    private func seedTwoStashes(_ dir: URL, _ runner: Runner) async throws {
        let stash = StashOps(runner: runner)
        try Data("first edit\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await stash.push(message: "first")
        try Data("second edit\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await stash.push(message: "second")
    }

    private func fileContent(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
    }

    @Test("list parses selector, 40-hex SHA, date, and subject — newest first")
    func listParsesEntries() async throws {
        let (dir, runner) = try await makeRepo("list")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)

        let entries = try await StashOps(runner: runner).list()

        #expect(entries.count == 2)
        #expect(entries.map(\.ref) == ["stash@{0}", "stash@{1}"])
        #expect(entries.map(\.subject) == ["On main: second", "On main: first"])
        for entry in entries {
            #expect(entry.sha.count == 40)
            let isHex = entry.sha.allSatisfy(\.isHexDigit)
            #expect(isHex)
            #expect(entry.createdAt != nil)
        }
        let listedTip = try await runner.run(["rev-parse", "refs/stash"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(entries[0].sha == listedTip)
    }

    @Test("list on a repo with no stash entries is empty")
    func listEmpty() async throws {
        let (dir, runner) = try await makeRepo("empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await StashOps(runner: runner).list().isEmpty)
    }

    @Test("apply restores the files and KEEPS the entry")
    func applyKeepsEntry() async throws {
        let (dir, runner) = try await makeRepo("apply")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let stash = StashOps(runner: runner)

        let outcome = try await stash.apply("stash@{1}")

        #expect(outcome == .applied)
        #expect(try fileContent(dir) == "first edit\n")
        #expect(try await stash.list().count == 2)
    }

    @Test("conflicted apply reports .conflicted with git's explanation; entry kept")
    func applyConflicted() async throws {
        let (dir, runner) = try await makeRepo("applyconflict")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stash = StashOps(runner: runner)
        try Data("stashed line\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await stash.push(message: "conflicting work")
        try Data("committed line\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "diverge"])

        let outcome = try await stash.apply("stash@{0}")

        guard case let .conflicted(detail) = outcome else {
            Issue.record("expected .conflicted, got \(outcome)")
            return
        }
        #expect(!detail.isEmpty)
        #expect(try await stash.list().count == 1)
    }

    @Test("pop targets a specific entry: applies it and drops exactly it")
    func popSpecificEntry() async throws {
        let (dir, runner) = try await makeRepo("popref")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let stash = StashOps(runner: runner)

        let outcome = try await stash.pop("stash@{1}")

        #expect(outcome == .applied)
        #expect(try fileContent(dir) == "first edit\n")
        let remaining = try await stash.list()
        #expect(remaining.map(\.subject) == ["On main: second"])
    }

    @Test("conflicted pop by ref keeps the entry (verified by SHA, not index)")
    func popByRefConflictedKeepsEntry() async throws {
        let (dir, runner) = try await makeRepo("popconflict")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stash = StashOps(runner: runner)
        try Data("stashed line\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await stash.push(message: "conflicting work")
        try Data("committed line\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "diverge"])
        let sha = try #require(try await stash.list().first).sha

        let outcome = try await stash.pop("stash@{0}")

        guard case .keptDueToConflict = outcome else {
            Issue.record("expected .keptDueToConflict, got \(outcome)")
            return
        }
        #expect(try await stash.list().map(\.sha) == [sha])
    }

    @Test("drop removes the entry and returns the SHA a safety copy points at")
    func dropReturnsSHA() async throws {
        let (dir, runner) = try await makeRepo("drop")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let stash = StashOps(runner: runner)
        let listedSHA = try #require(try await stash.list().last).sha

        let droppedSHA = try await stash.drop("stash@{1}")

        #expect(droppedSHA == listedSHA)
        let remaining = try await stash.list()
        #expect(remaining.map(\.subject) == ["On main: second"])
        // The commit object still exists (drop doesn't gc) — this is
        // what an ADR 0033 safety ref written beforehand preserves.
        let objectAlive = try await runner.run(
            ["cat-file", "-e", droppedSHA],
            throwOnNonZero: false
        )
        #expect(objectAlive.exitCode == 0)
    }

    @Test("an out-of-range selector throws instead of acting on the wrong entry")
    func bogusRefThrows() async throws {
        let (dir, runner) = try await makeRepo("bogus")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedTwoStashes(dir, runner)
        let stash = StashOps(runner: runner)

        await #expect(throws: GitError.self) {
            _ = try await stash.apply("stash@{9}")
        }
        await #expect(throws: GitError.self) {
            _ = try await stash.drop("stash@{9}")
        }
        #expect(try await stash.list().count == 2)
    }
}
