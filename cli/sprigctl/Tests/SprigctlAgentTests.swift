import Foundation
import IPCSchema
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

        // `--duration 2.5` rather than something tighter so this test
        // is robust to Windows's ~2 s filesystem-propagation latency.
        // On Windows, the `v2\n` write above may not be visible to the
        // `git status` subprocess that `RepoAgent` spawns until ~2 s
        // after the write returns; the agent must keep running long
        // enough for the polling watcher to observe the change after
        // it propagates. macOS/Linux see the change instantly so the
        // 2.5 s budget is just slack on those platforms.
        let out = try await Sprigctl.run([
            "agent",
            "--duration", "2.5",
            "--polling-interval", "0.1",
            repo.path
        ])
        #expect(out.exitCode == 0)

        // stdout is one `Envelope<AgentEvent>` JSON per line. Decode
        // via the canonical `IPCSchema.EnvelopeCodec.decode` (uses
        // `JSONDecoder` under the hood) rather than reaching for
        // `JSONSerialization.jsonObject(...) as? [String: Any]`. The
        // typed-decode path goes through a different Foundation entry
        // point that's been more reliable on Windows CI; using the
        // production codec here also means tests exercise the same
        // wire-format contract a real client would.
        //
        // Each line is whitespace-trimmed before decode because Windows
        // CRLF leaves "\r" on every substring after splitting on "\n",
        // and we don't want that "\r" to confuse the decoder's
        // single-document boundary detection.
        let envelopes = decodeAgentEventEnvelopes(in: out.stdout)
        let sawMatch = envelopes.contains { envelope in
            guard case let .badgeChanged(payload) = envelope.message else { return false }
            return payload.path.contains("a.txt") && payload.badge == "modified"
        }
        #expect(
            sawMatch,
            "expected at least one badgeChanged envelope on stdout, got:\n\(out.stdout)"
        )
    }

    /// Walks `stdout` line-by-line and returns each
    /// `Envelope<AgentEvent>` that decodes cleanly via
    /// ``IPCSchema/EnvelopeCodec/decode(_:from:)``. Lines that don't
    /// decode are skipped silently — the agent's stdout sometimes
    /// includes diagnostic or comment lines (`# agent: …`) the codec
    /// rightly rejects.
    ///
    /// **Why `enumerateLines(invoking:)` rather than
    /// `split(separator: "\n", ...)`.** Swift's `String` is a
    /// collection of *grapheme clusters*; per Unicode TR#14 a CRLF
    /// pair (`\r\n`) is **one** cluster, not two. So `split(separator:
    /// "\n", ...)` against a CRLF-terminated string returns a single
    /// element containing every line concatenated — the separator
    /// `"\n"` (one cluster) never matches any cluster in the input
    /// (every newline cluster there is `"\r\n"`).
    ///
    /// This bites on Windows specifically: Swift's `print()` writes
    /// to stdout through a runtime that translates `"\n"` to `"\r\n"`
    /// at the C-runtime layer (text-mode FILE * semantics), so the
    /// captured pipe bytes carry CRLF. Linux and macOS pipes are
    /// byte-for-byte and stay LF-only.
    ///
    /// `String.enumerateLines(invoking:)` is the Foundation-canonical
    /// line iterator that handles LF, CRLF, CR-alone, and NEL
    /// uniformly. Use it for any byte stream that might originate
    /// from a different platform.
    private func decodeAgentEventEnvelopes(in stdout: String) -> [Envelope<AgentEvent>] {
        var envelopes: [Envelope<AgentEvent>] = []
        stdout.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
            if let envelope = try? EnvelopeCodec.decode(AgentEvent.self, from: data) {
                envelopes.append(envelope)
            }
        }
        return envelopes
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
        // on shutdown (per slice A9, reason `agent_shutdown`); decode
        // every envelope and assert no `.badgeChanged` case appears.
        // See `emitsBadgeChangedOnStartup` for the rationale on using
        // `EnvelopeCodec.decode` rather than `JSONSerialization`.
        let envelopes = decodeAgentEventEnvelopes(in: out.stdout)
        let badgeChangedCount = envelopes.reduce(into: 0) { count, envelope in
            if case .badgeChanged = envelope.message { count += 1 }
        }
        #expect(
            badgeChangedCount == 0,
            "expected no badgeChanged envelopes, got stdout:\n\(out.stdout)"
        )
    }

    @Test("agent --stats-interval prints periodic '# stats: …' lines on stderr")
    func statsIntervalPrintsLines() async throws {
        let repo = try Sprigctl.mkRepo("agent-stats")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)

        // `--duration 5.0` at `--stats-interval 0.2` budgets for ≥25
        // stats ticks on a fast runner; the assertion below requires
        // only ≥2. Earlier values failed on Windows hosted runners:
        //
        // - PR #70: 0.6 → 1.5 s after a Windows CI flake left only
        //   ~0.4 s for stats after agent startup.
        // - PR #92 (CI run 25696584319): 1.5 s flaked again — the
        //   Windows agent printed `# agent: watching <path>` but
        //   zero stats lines in 1.5 s. Hosted-runner agent startup
        //   (process spawn + Foundation init + git init + initial
        //   refresh of a fresh repo) burned through the entire
        //   window.
        //
        // 5.0 s is generous headroom. macOS / Linux runners exit at
        // the `--duration` cutoff regardless, so the runtime cost
        // is uniform across platforms.
        //
        // Structural alternative (deferred): stream stderr in real
        // time and exit as soon as we've seen ≥2 stats lines.
        // Requires teaching `Sprigctl.run` to drain stderr
        // line-by-line with a configurable predicate-based early
        // exit, and ideally an `# agent: ready` marker emitted by
        // the agent after its first refresh so the test can
        // distinguish startup from steady-state. Bigger refactor
        // than this stop-gap deserves.
        let out = try await Sprigctl.run([
            "agent",
            "--duration", "5.0",
            "--polling-interval", "0.1",
            "--stats-interval", "0.2",
            repo.path
        ])
        #expect(out.exitCode == 0)

        // Use `enumerateLines(invoking:)` rather than
        // `split(separator: "\n", ...)`. Stderr is currently written
        // via `FileHandle.standardError.write(Data(...).utf8)` (no
        // text-mode translation, LF on every platform), so split would
        // work today — but the canonical iterator tolerates CRLF if
        // anyone ever changes the stderr write path. Same reasoning as
        // `decodeAgentEventEnvelopes(in:)` above; defense-in-depth.
        var statsLines: [String] = []
        out.stderr.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("# stats: ") {
                statsLines.append(trimmed)
            }
        }
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
