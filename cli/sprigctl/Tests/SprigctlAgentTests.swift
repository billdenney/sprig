import Foundation
import Testing

// `sprigctl agent` end-to-end CLI tests. Lives in its own file (split
// from `SprigctlTests.swift`) so neither file trips SwiftLint's
// `file_length` cap as the agent surface grows. Test helpers (the
// `Sprigctl` namespace enum) are still in `SprigctlSupport.swift`.

@Suite("sprigctl agent")
struct SprigctlAgentTests {
    @Test("agent --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["agent", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.lowercased().contains("agent"))
        #expect(out.stdout.contains("--duration"))
        #expect(out.stdout.contains("--polling"))
        #expect(out.stdout.contains("--polling-interval"))
        #expect(out.stdout.contains("--stats-interval"))
    }

    @Test("agent on a dirty repo with --duration emits at least one badgeChanged envelope on stdout")
    func emitsBadgeChangedOnStartup() async throws {
        let repo = try Sprigctl.mkRepo("agent-startup")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("v1\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)
        // Mark the file dirty BEFORE spawning the agent so the forced
        // initial refresh (in `RepoAgent.start()`) produces a non-empty
        // diff that the broadcaster fans out as one envelope.
        try Sprigctl.write("v2\n", to: repo.appendingPathComponent("a.txt"))

        let out = try await Sprigctl.run([
            "agent",
            "--duration", "1.0",
            "--polling-interval", "0.1",
            repo.path
        ])
        #expect(out.exitCode == 0)

        // stdout is JSON envelopes, one per line. The envelope's
        // `Codable` flattens the message's `kind` + `payload` into the
        // envelope's top-level keys (alongside `id`, `schemaVersion`),
        // so we assert at the top level — not under a `message` key.
        // Uses a guard chain rather than a multi-clause `if`: the latter
        // form trips both SwiftLint's `opening_brace` (wants `{` on the
        // same line) and SwiftFormat's `wrapMultilineStatementBraces`
        // (wants `{` on its own line). The guard chain sidesteps that.
        var sawMatch = false
        for line in out.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard (obj["kind"] as? String) == "badgeChanged",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["path"] as? String)?.contains("a.txt") == true,
                  (payload["badge"] as? String) == "modified"
            else { continue }
            sawMatch = true
            break
        }
        #expect(sawMatch, "expected at least one badgeChanged envelope on stdout, got:\n\(out.stdout)")
    }

    @Test("agent on a clean repo with --duration exits 0 with no envelopes")
    func noEnvelopesOnCleanRepo() async throws {
        let repo = try Sprigctl.mkRepo("agent-clean")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)

        let out = try await Sprigctl.run([
            "agent",
            "--duration", "0.5",
            "--polling-interval", "0.1",
            repo.path
        ])
        #expect(out.exitCode == 0)
        // Clean repo → empty diff on initial refresh → no `badgeChanged`
        // envelopes. The agent does emit one `subscriptionEnded` envelope
        // on shutdown (per slice A9, reason `agent_shutdown`); we filter
        // it out here since the assertion is about badge changes, not
        // shutdown lifecycle.
        var badgeChangedLines = 0
        for line in out.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if (obj["kind"] as? String) == "badgeChanged" {
                badgeChangedLines += 1
            }
        }
        #expect(badgeChangedLines == 0, "expected no badgeChanged envelopes, got stdout:\n\(out.stdout)")
    }

    @Test("agent --stats-interval prints periodic '# stats: …' lines on stderr")
    func statsIntervalPrintsLines() async throws {
        let repo = try Sprigctl.mkRepo("agent-stats")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)

        // 0.6 s of runtime at a 0.2 s tick gives 2-3 stats lines.
        let out = try await Sprigctl.run([
            "agent",
            "--duration", "0.6",
            "--polling-interval", "0.1",
            "--stats-interval", "0.2",
            repo.path
        ])
        #expect(out.exitCode == 0)

        let statsLines = out.stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("# stats: ") }
        #expect(statsLines.count >= 2, "expected at least 2 stats lines, got stderr:\n\(out.stderr)")

        // Each stats line's payload is JSON. Sample-decode the first
        // one and assert the wire shape (sorted keys, expected fields).
        guard let first = statsLines.first else { return }
        let prefix = "# stats: "
        let jsonText = String(first.dropFirst(prefix.count))
        let data = try #require(jsonText.data(using: .utf8))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "stats payload should decode to a JSON object"
        )
        // `refreshes` must be present and >= 1 (the forced initial refresh).
        let refreshes = try #require(obj["refreshes"] as? Int)
        #expect(refreshes >= 1)
        // `outcome` should be "applied" on a clean repo.
        #expect((obj["outcome"] as? String) == "applied")
    }
}
