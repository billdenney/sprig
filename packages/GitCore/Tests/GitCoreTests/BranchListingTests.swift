// BranchListingTests.swift
//
// Unit + integration tests for `BranchListing` — the parser for
// `git for-each-ref refs/heads/ -z --format=…` output. Unit tests
// cover the parser shape directly with synthesized buffers; the
// integration test spawns real git against a fixture repo and
// verifies the full end-to-end pipeline.

import Foundation
@testable import GitCore
import Testing

@Suite("BranchListing — parser + against real git")
struct BranchListingTests {
    // MARK: - Pure parser tests

    private func makeEntry(short: String, full: String, sha: String, isHead: Bool) -> Data {
        var data = Data()
        data.append(Data(short.utf8))
        data.append(0x09)
        data.append(Data(full.utf8))
        data.append(0x09)
        data.append(Data(sha.utf8))
        data.append(0x09)
        data.append(Data((isHead ? "*" : " ").utf8))
        data.append(0x0A) // newline-terminated, matching git for-each-ref's default
        return data
    }

    @Test("parse returns empty array for empty input")
    func parseEmpty() throws {
        let parsed = try BranchListing.parse(Data())
        #expect(parsed.isEmpty)
    }

    @Test("parse handles a single branch entry")
    func parseOne() throws {
        let sha = String(repeating: "a", count: 40)
        let entry = makeEntry(
            short: "main",
            full: "refs/heads/main",
            sha: sha,
            isHead: true
        )
        let parsed = try BranchListing.parse(entry)
        #expect(parsed.count == 1)
        let branch = try #require(parsed.first)
        #expect(branch.shortName == "main")
        #expect(branch.fullName == "refs/heads/main")
        #expect(branch.sha == sha)
        #expect(branch.isHead == true)
    }

    @Test("parse handles multiple branches; HEAD marker distinguishes the current one")
    func parseMany() throws {
        let shaA = String(repeating: "a", count: 40)
        let shaB = String(repeating: "b", count: 40)
        var data = Data()
        data.append(makeEntry(short: "main", full: "refs/heads/main", sha: shaA, isHead: false))
        data.append(makeEntry(short: "feature/x", full: "refs/heads/feature/x", sha: shaB, isHead: true))
        let parsed = try BranchListing.parse(data)
        #expect(parsed.count == 2)
        #expect(parsed[0].shortName == "main")
        #expect(parsed[0].isHead == false)
        #expect(parsed[1].shortName == "feature/x")
        #expect(parsed[1].isHead == true)
    }

    @Test("parse throws GitError.parseFailure on a malformed entry (too few fields)")
    func parseMalformed() {
        var data = Data()
        data.append(Data("main".utf8))
        data.append(0x09)
        data.append(Data("refs/heads/main".utf8))
        data.append(0x0A) // newline-terminated, but only 2 of 4 fields
        #expect(throws: GitError.self) {
            try BranchListing.parse(data)
        }
    }

    // MARK: - Integration tests against real git

    private func makeRepoWithBranches() async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-branchlist-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        _ = try await runner.run(["branch", "feature/x"])
        _ = try await runner.run(["branch", "other"])
        return (dir, runner)
    }

    @Test("end-to-end: git for-each-ref + BranchListing.parse returns the expected branches")
    func integrationListsBranches() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await runner.run([
            "for-each-ref",
            "--format=\(BranchListing.formatString)",
            "refs/heads/"
        ])
        let parsed = try BranchListing.parse(output.stdout)

        let names = parsed.map(\.shortName).sorted()
        #expect(names == ["feature/x", "main", "other"])

        let headBranches = parsed.filter(\.isHead).map(\.shortName)
        #expect(headBranches == ["main"], "HEAD marker should land on the checked-out branch only")

        for branch in parsed {
            #expect(branch.sha.count == 40, "SHA should be the 40-char hex form")
            #expect(branch.fullName == "refs/heads/\(branch.shortName)")
        }
    }
}
