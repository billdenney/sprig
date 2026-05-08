import Foundation
import Testing

// `sprigctl lfs` end-to-end CLI tests. Lives in its own file so
// neither it nor `SprigctlTests.swift` trips SwiftLint's `file_length`
// or `type_body_length` caps as the surface grows.

@Suite("sprigctl lfs")
struct SprigctlLFSTests {
    // MARK: - Mode-flag plumbing

    @Test("lfs --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["lfs", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.lowercased().contains("lfs"))
        #expect(out.stdout.contains("--status"))
    }

    @Test("lfs without --status errors with a helpful message")
    func errorsWithoutMode() async throws {
        let out = try await Sprigctl.run(["lfs"])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("--status"))
    }

    // MARK: - --status

    @Test("lfs --status on a repo with no .gitattributes reports no LFS rules")
    func statusOnRepoWithoutLFS() async throws {
        let repo = try Sprigctl.mkRepo("lfs-status-clean")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)

        let out = try await Sprigctl.run(["lfs", "--status", repo.path])
        #expect(out.exitCode == 0)
        // "no LFS rules in .gitattributes" is the only assertion that
        // doesn't depend on the runner host's git config — we wrote
        // no .gitattributes so the local repo has zero LFS rules.
        // We can't assert on the configured / ready fields here
        // because hosted CI runners (macOS, Windows) ship with
        // git-lfs installed and `git lfs install --system` already
        // run, which sets `filter.lfs.*` system-wide and propagates
        // to this fresh repo. The dedicated unconfigured assertion
        // lives in `statusReportsUnconfiguredAfterLocalUnset` —
        // that test sets a local-level filter that overrides any
        // inherited config, making the assertion environment-
        // independent.
        #expect(out.stdout.contains("no LFS rules in .gitattributes"))
        // Fields are always present in the output regardless of value.
        #expect(out.stdout.contains("configured:"))
        #expect(out.stdout.contains("ready:"))
    }

    @Test("lfs --status reports configured == no when local filter is whitespace-only")
    func statusReportsUnconfiguredAfterLocalUnset() async throws {
        let repo = try Sprigctl.mkRepo("lfs-status-local-empty")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        // Local-level filter.lfs.clean set to whitespace-only
        // overrides any global / system level inherited config
        // (local has highest precedence). Our probe trims and
        // rejects empty values — so this assertion is environment-
        // independent: it works even on hosted CI runners where
        // `git lfs install --system` was run by the package manager.
        try await Sprigctl.spawnGit(
            ["config", "--local", "filter.lfs.clean", "   "],
            cwd: repo
        )
        let out = try await Sprigctl.run(["lfs", "--status", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("configured: no"))
        #expect(out.stdout.contains("ready:      no"))
    }

    @Test("lfs --status surfaces .gitattributes LFS rules")
    func statusWithLFSRules() async throws {
        let repo = try Sprigctl.mkRepo("lfs-status-rules")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write(
            """
            *.psd filter=lfs diff=lfs merge=lfs -text
            images/*.png filter=lfs

            """,
            to: repo.appendingPathComponent(".gitattributes")
        )

        let out = try await Sprigctl.run(["lfs", "--status", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("2 LFS patterns in .gitattributes"))
        #expect(out.stdout.contains("*.psd"))
        #expect(out.stdout.contains("images/*.png"))
    }

    @Test("lfs --status reports configured == yes after `git config filter.lfs.clean`")
    func statusReportsConfiguredAfterLocalFilter() async throws {
        let repo = try Sprigctl.mkRepo("lfs-status-configured")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try await Sprigctl.spawnGit(
            ["config", "--local", "filter.lfs.clean", "git-lfs clean -- %f"],
            cwd: repo
        )

        let out = try await Sprigctl.run(["lfs", "--status", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("configured: yes"))
    }

    @Test("lfs --status --json emits parseable JSON")
    func statusJSON() async throws {
        let repo = try Sprigctl.mkRepo("lfs-status-json")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write(
            "*.psd filter=lfs\n",
            to: repo.appendingPathComponent(".gitattributes")
        )

        let out = try await Sprigctl.run(["lfs", "--status", "--json", repo.path])
        #expect(out.exitCode == 0)
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(parsed as? [String: Any])
        // Wire-stable keys (sorted JSON).
        #expect(dict["configured"] is Bool)
        #expect(dict["isReady"] is Bool)
        #expect(dict["binaryAvailable"] is Bool)
        let patterns = try #require(dict["trackedPatterns"] as? [[String: Any]])
        #expect(patterns.count == 1)
        #expect(patterns[0]["pattern"] as? String == "*.psd")
        #expect(patterns[0]["lineNumber"] as? Int == 1)
    }
}
