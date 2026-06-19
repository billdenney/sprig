// OperationProvenanceTests.swift
//
// ADR 0088 prerequisite — the Sprig-vs-external provenance signal.

import Foundation
@testable import GitCore
import Testing

@Suite("OperationProvenance — Sprig-authored signal (real git)", .serialized)
struct OperationProvenanceTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-prov-\(label)-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    private let shaA = String(repeating: "a", count: 40)
    private let shaB = String(repeating: "b", count: 40)

    @Test("records and queries authored commits; filters external")
    func recordAndQuery() async throws {
        let (dir, runner) = try await makeRepo("query")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prov = OperationProvenance(runner: runner)

        #expect(try await prov.authoredCommits().isEmpty)
        try await prov.recordAuthored(shaA)
        #expect(try await prov.authoredCommits() == [shaA])
        // Of two candidates, only the un-recorded one is "external".
        #expect(try await prov.externalCommits(among: [shaA, shaB]) == [shaB])
    }

    @Test("recording the same commit twice keeps a single entry")
    func dedupes() async throws {
        let (dir, runner) = try await makeRepo("dedupe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prov = OperationProvenance(runner: runner)
        try await prov.recordAuthored(shaA)
        try await prov.recordAuthored(shaA)
        try await prov.recordAuthored("  \(shaA)  ") // whitespace-trimmed, still same
        #expect(try await prov.authoredCommits() == [shaA])
        try await prov.recordAuthored("") // ignored
        #expect(try await prov.authoredCommits().count == 1)
    }

    @Test("batch recordAuthored persists every SHA in one atomic write")
    func batchRecord() async throws {
        let (dir, runner) = try await makeRepo("batch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prov = OperationProvenance(runner: runner)
        let shaC = String(repeating: "c", count: 40)
        // A rewrite recording N commits at once — must NOT lose any.
        try await prov.recordAuthored([shaA, shaB, shaC, shaA, ""]) // dup + empty tolerated
        #expect(try await prov.authoredCommits() == [shaA, shaB, shaC])
        #expect(try await prov.externalCommits(among: [shaA, shaB, shaC]).isEmpty)
    }

    @Test("provenance is durable — a fresh instance reads prior records")
    func durable() async throws {
        let (dir, runner) = try await makeRepo("durable")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await OperationProvenance(runner: runner).recordAuthored(shaA)
        try await OperationProvenance(runner: runner).recordHeads(["refs/heads/main": shaB])
        // A brand-new instance (simulating a Sprig restart) sees both.
        let reborn = OperationProvenance(runner: runner)
        #expect(try await reborn.authoredCommits() == [shaA])
        #expect(try await reborn.lastKnownHeads() == ["refs/heads/main": shaB])
        // Stored under the git dir, not the worktree.
        let store = dir.appendingPathComponent(".git/sprig/provenance.json")
        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    @Test("a missing provenance file reads as empty, not an error")
    func missingIsEmpty() async throws {
        let (dir, runner) = try await makeRepo("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prov = OperationProvenance(runner: runner)
        #expect(try await prov.authoredCommits().isEmpty)
        #expect(try await prov.lastKnownHeads().isEmpty)
        #expect(try await prov.externalCommits(among: [shaA]) == [shaA]) // all external
    }

    @Test("authored set is shared across linked worktrees (common git dir)")
    func sharedAcrossWorktrees() async throws {
        let (dir, runner) = try await makeRepo("shared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let linked = dir.appendingPathComponent("linked-wt")
        _ = try await runner.run(["worktree", "add", linked.path, "-b", "side"])
        defer { try? FileManager.default.removeItem(at: linked) }

        // Record from the MAIN worktree...
        try await OperationProvenance(runner: runner).recordAuthored(shaA)
        // ...and read it from the LINKED worktree (commit provenance is repo-wide).
        let fromLinked = OperationProvenance(runner: Runner(defaultWorkingDirectory: linked))
        #expect(try await fromLinked.authoredCommits().contains(shaA))
    }
}
