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

    // MARK: - --check

    /// Real git-lfs pointer file body. SHA-256 is fabricated but
    /// well-formed (64 lowercase hex chars).
    private let pointerBody = """
    version https://git-lfs.github.com/spec/v1
    oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    size 1024

    """

    @Test("lfs --check and --status are mutually exclusive")
    func checkAndStatusExclusive() async throws {
        let repo = try Sprigctl.mkRepo("lfs-check-exclusive")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)

        let out = try await Sprigctl.run(
            ["lfs", "--status", "--check", "README.md", repo.path]
        )
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("mutually exclusive"))
    }

    @Test("lfs --check on a missing path errors with a helpful message")
    func checkPathMissing() async throws {
        let repo = try Sprigctl.mkRepo("lfs-check-missing")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)

        let out = try await Sprigctl.run(
            ["lfs", "--check", "no-such-file.bin", repo.path]
        )
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("not found"))
    }

    @Test("lfs --check on a directory errors")
    func checkPathIsDirectory() async throws {
        let repo = try Sprigctl.mkRepo("lfs-check-dir")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("subdir"),
            withIntermediateDirectories: true
        )

        let out = try await Sprigctl.run(["lfs", "--check", "subdir", repo.path])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("directory"))
    }

    @Test("lfs --check on an untracked, non-pointer file reports tracked: no, content: not a pointer")
    func checkUntrackedRegularFile() async throws {
        let repo = try Sprigctl.mkRepo("lfs-check-regular")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("hello\n", to: repo.appendingPathComponent("README.md"))

        let out = try await Sprigctl.run(["lfs", "--check", "README.md", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("path:    README.md"))
        #expect(out.stdout.contains("tracked: no"))
        #expect(out.stdout.contains("content: not a pointer"))
    }

    @Test("lfs --check on a pointer file in a tracked path reports tracked + pointer")
    func checkTrackedPointerFile() async throws {
        let repo = try Sprigctl.mkRepo("lfs-check-tracked-pointer")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("*.psd filter=lfs\n", to: repo.appendingPathComponent(".gitattributes"))
        try Sprigctl.write(pointerBody, to: repo.appendingPathComponent("big.psd"))

        let out = try await Sprigctl.run(["lfs", "--check", "big.psd", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("tracked: yes"))
        #expect(out.stdout.contains("filter=lfs"))
        #expect(out.stdout.contains("content: pointer"))
        #expect(out.stdout.contains("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
        #expect(out.stdout.contains("1024 bytes"))
    }

    @Test("lfs --check on a tracked file with real content reports the un-smudged note")
    func checkTrackedNonPointer() async throws {
        let repo = try Sprigctl.mkRepo("lfs-check-tracked-actual")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("*.psd filter=lfs\n", to: repo.appendingPathComponent(".gitattributes"))
        try Sprigctl.write("not a pointer\n", to: repo.appendingPathComponent("big.psd"))

        let out = try await Sprigctl.run(["lfs", "--check", "big.psd", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("tracked: yes"))
        #expect(out.stdout.contains("content: not a pointer"))
        #expect(out.stdout.contains("not yet smudged"))
    }

    @Test("lfs --check on an untracked file containing a pointer flags the leftover")
    func checkUntrackedPointer() async throws {
        let repo = try Sprigctl.mkRepo("lfs-check-leftover")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        // No .gitattributes — the path isn't LFS-tracked.
        try Sprigctl.write(pointerBody, to: repo.appendingPathComponent("legacy.bin"))

        let out = try await Sprigctl.run(["lfs", "--check", "legacy.bin", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("tracked: no"))
        #expect(out.stdout.contains("content: pointer"))
        #expect(out.stdout.contains("leftover"))
    }

    @Test("lfs --check --json emits parseable JSON")
    func checkJSON() async throws {
        let repo = try Sprigctl.mkRepo("lfs-check-json")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("*.psd filter=lfs\n", to: repo.appendingPathComponent(".gitattributes"))
        try Sprigctl.write(pointerBody, to: repo.appendingPathComponent("big.psd"))

        let out = try await Sprigctl.run(
            ["lfs", "--check", "big.psd", "--json", repo.path]
        )
        #expect(out.exitCode == 0)
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(parsed as? [String: Any])
        #expect(dict["target"] as? String == "big.psd")
        #expect(dict["isLFSTracked"] as? Bool == true)
        #expect(dict["isPointerFile"] as? Bool == true)
        #expect(dict["filter"] as? String == "lfs")
        let pointer = try #require(dict["pointer"] as? [String: Any])
        #expect(pointer["size"] as? Int == 1024)
        #expect(
            pointer["oidSHA256"] as? String
                == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        )
    }
}
