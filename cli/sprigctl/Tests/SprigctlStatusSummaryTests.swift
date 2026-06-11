// SprigctlStatusSummaryTests.swift
//
// `sprigctl status --summary` end-to-end — the ADR 0064 dashboard's
// CLI face. Own file (the main SprigctlTests.swift is near the
// file-length cap).

import Foundation
import GitCore
import Testing

@Suite("sprigctl status --summary")
struct SprigctlStatusSummaryTests {
    @Test("dirty repo summary: counts, relationship line, safety net, stale-work nudge")
    func dirtySummary() async throws {
        let repo = try Sprigctl.mkRepo("status-summary")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)
        // One of each bucket: staged (new b.txt), unstaged (a.txt
        // edit), untracked (wip.txt).
        try Sprigctl.write("new\n", to: repo.appendingPathComponent("b.txt"))
        try await Sprigctl.spawnGit(["add", "b.txt"], cwd: repo)
        try Sprigctl.write("edit\n", to: repo.appendingPathComponent("a.txt"))
        try Sprigctl.write("wip\n", to: repo.appendingPathComponent("wip.txt"))

        let out = try await Sprigctl.run(["status", "--summary", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("branch: main"))
        #expect(out.stdout.contains("tree: 1 staged, 1 unstaged, 1 untracked, 0 conflicted"))
        #expect(out.stdout.contains("safety net: 0 snapshot(s), 0 backup(s)"))
        // ADR 0077 stale-work line (dirty tree + a commit exists →
        // "main: 3 changed file(s), no commit in 0 day(s)").
        #expect(out.stdout.contains("main: 3 changed file(s), no commit in"))
    }

    @Test("--summary --json emits the documented wire shape")
    func summaryJSON() async throws {
        let repo = try Sprigctl.mkRepo("status-summary-json")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)

        let out = try await Sprigctl.run(["status", "--summary", "--json", repo.path])
        #expect(out.exitCode == 0)
        let object = try JSONSerialization.jsonObject(with: Data(out.stdout.utf8))
        let wire = try #require(object as? [String: Any])
        #expect(wire["branch"] as? String == "main")
        #expect(wire["stagedCount"] as? Int == 0)
        #expect(wire["conflictedCount"] as? Int == 0)
        #expect(wire["midOperation"] as? String == "none")
        #expect(wire["snapshotCount"] as? Int == 0)
        #expect(wire["lastCommitDate"] is String, "ISO-8601 committer date present")
    }
}
