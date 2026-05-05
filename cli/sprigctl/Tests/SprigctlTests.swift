import Foundation
import Testing

// Test helpers live in `SprigctlSupport.swift` (`Sprigctl` enum). The
// suites below are split by subcommand so each one stays under
// SwiftLint's type-body-length cap and the failure surface in CI maps
// cleanly to "which subcommand broke."

// MARK: - General

@Suite("sprigctl — general")
struct SprigctlGeneralTests {
    @Test("sprigctl --help exits 0 and lists subcommands")
    func helpExits0AndListsSubcommands() async throws {
        let out = try await Sprigctl.run(["--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("status"))
        #expect(out.stdout.contains("version"))
        #expect(out.stdout.contains("watch"))
        #expect(out.stdout.contains("repos"))
        #expect(out.stdout.contains("log"))
        #expect(out.stdout.contains("agent"))
    }

    @Test("sprigctl version prints sprigctl + git versions")
    func versionPrintsSprigctlGitVersions() async throws {
        let out = try await Sprigctl.run(["version"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("sprigctl"))
        #expect(out.stdout.contains("git"))
    }
}

// MARK: - Status

@Suite("sprigctl status")
struct SprigctlStatusTests {
    @Test("on a fresh repo prints clean summary")
    func freshRepo() async throws {
        let repo = try Sprigctl.mkRepo("clean")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("hi\n", to: repo.appendingPathComponent("README.md"))
        try await Sprigctl.spawnGit(["add", "README.md"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "initial"], cwd: repo)

        let out = try await Sprigctl.run(["status", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("branch: main"))
        #expect(out.stdout.contains("(clean)"))
    }

    @Test("reports untracked files in human output")
    func untrackedFiles() async throws {
        let repo = try Sprigctl.mkRepo("untracked")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("hello\n", to: repo.appendingPathComponent("hello.txt"))

        let out = try await Sprigctl.run(["status", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("??  hello.txt"))
    }

    @Test("--json emits parseable JSON with entries array")
    func json() async throws {
        let repo = try Sprigctl.mkRepo("json")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("hello\n", to: repo.appendingPathComponent("hello.txt"))

        let out = try await Sprigctl.run(["status", "--json", repo.path])
        #expect(out.exitCode == 0)
        let data = try #require(out.stdout.data(using: .utf8))
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let entries = try #require(parsed["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["kind"] as? String == "untracked")
        #expect(entries.first?["path"] as? String == "hello.txt")
    }

    @Test("on a non-repo path exits non-zero with a useful error")
    func nonRepoPath() async throws {
        let tmp = try Sprigctl.mkRepo("notarepo")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let out = try await Sprigctl.run(["status", tmp.path])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("not a git repository") || out.stderr.contains("fatal"))
    }
}

// MARK: - Watch

@Suite("sprigctl watch")
struct SprigctlWatchTests {
    @Test("watch --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["watch", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.lowercased().contains("watch"))
        #expect(out.stdout.contains("--json"))
        #expect(out.stdout.contains("--duration"))
        #expect(out.stdout.contains("--polling"))
        #expect(out.stdout.contains("--polling-interval"))
    }

    #if !os(macOS)
        @Test("on non-macOS uses the polling watcher and exits cleanly with --duration")
        func pollingExits() async throws {
            let tmp = try Sprigctl.mkRepo("watch-polling")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let out = try await Sprigctl.run([
                "watch",
                "--duration", "0.6",
                "--polling-interval", "0.05",
                tmp.path
            ])
            #expect(out.exitCode == 0)
        }
    #endif

    #if os(macOS)
        /// End-to-end check that `sprigctl watch --duration 0.2` exits
        /// cleanly when backed by `FSEventsWatcher` on macOS. This is the
        /// only test that exercises `WatcherKit/Mac/WatcherKitMac.swift`
        /// in CI.
        ///
        /// History: previously CI-disabled with "FSEvents hang on hosted
        /// macos-14" — but the watchdog stack traces on PR #16 showed the
        /// hang was actually `[NSConcreteTask waitUntilExit]` inside
        /// `Sprigctl.run`, not FSEvents itself. That race is now fixed
        /// (`ProcessTerminationGate` set up before `process.run()` in
        /// `SprigctlSupport`), so we re-enable here. The job-level
        /// `timeout-minutes: 15` is the safety net if a residual flake
        /// surfaces; the macOS test watchdog will capture diagnostics.
        @Test("watch --duration 0.2 exits cleanly")
        func macShortDurationExits() async throws {
            let tmp = try Sprigctl.mkRepo("watch-mac")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let out = try await Sprigctl.run(["watch", "--duration", "0.2", tmp.path])
            #expect(out.exitCode == 0)
        }
    #endif
}

// MARK: - Repos

@Suite("sprigctl repos")
struct SprigctlReposTests {
    @Test("repos --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["repos", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("repos"))
        #expect(out.stdout.contains("--json"))
        #expect(out.stdout.contains("--max-depth"))
    }

    @Test("finds .git directories under a tree")
    func findsRepos() async throws {
        let root = try Sprigctl.mkRepo("repos-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("alpha/.git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested/beta/.git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-repo"),
            withIntermediateDirectories: true
        )

        let out = try await Sprigctl.run(["repos", root.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("alpha"))
        #expect(out.stdout.contains("beta"))
        #expect(!out.stdout.contains("not-a-repo"))
    }

    @Test("--json emits a JSON array of paths")
    func json() async throws {
        let root = try Sprigctl.mkRepo("repos-json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("only-one/.git"),
            withIntermediateDirectories: true
        )

        let out = try await Sprigctl.run(["repos", "--json", root.path])
        #expect(out.exitCode == 0)
        let data = try #require(out.stdout.data(using: .utf8))
        let arr = try #require(try JSONSerialization.jsonObject(with: data) as? [String])
        #expect(arr.count == 1)
        #expect(arr.first?.contains("only-one") == true)
    }
}

// MARK: - Log

@Suite("sprigctl log")
struct SprigctlLogTests {
    @Test("log --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["log", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("log"))
        #expect(out.stdout.contains("--max"))
        #expect(out.stdout.contains("--json"))
    }

    @Test("prints subjects in reverse-chronological order")
    func subjects() async throws {
        let repo = try Sprigctl.mkRepo("log-subjects")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        for i in 0 ..< 3 {
            try Sprigctl.write("v\(i)\n", to: repo.appendingPathComponent("a.txt"))
            try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
            try await Sprigctl.spawnGit(["commit", "-m", "commit \(i)"], cwd: repo)
        }

        let out = try await Sprigctl.run(["log", repo.path])
        #expect(out.exitCode == 0)
        let i2 = out.stdout.range(of: "commit 2")
        let i1 = out.stdout.range(of: "commit 1")
        let i0 = out.stdout.range(of: "commit 0")
        #expect(i2 != nil)
        #expect(i1 != nil)
        #expect(i0 != nil)
        if let r2 = i2, let r1 = i1, let r0 = i0 {
            #expect(r2.lowerBound < r1.lowerBound)
            #expect(r1.lowerBound < r0.lowerBound)
        }
    }

    @Test("--json emits a parseable array of commit objects")
    func json() async throws {
        let repo = try Sprigctl.mkRepo("log-json")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "the only commit"], cwd: repo)

        let out = try await Sprigctl.run(["log", "--json", repo.path])
        #expect(out.exitCode == 0)
        let data = try #require(out.stdout.data(using: .utf8))
        let arr = try #require(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        #expect(arr.count == 1)
        #expect(arr.first?["subject"] as? String == "the only commit")
        #expect(arr.first?["isMerge"] as? Bool == false)
    }

    @Test("--max 1 returns at most one commit")
    func max() async throws {
        let repo = try Sprigctl.mkRepo("log-max")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        for i in 0 ..< 3 {
            try Sprigctl.write("v\(i)\n", to: repo.appendingPathComponent("a.txt"))
            try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
            try await Sprigctl.spawnGit(["commit", "-m", "c\(i)"], cwd: repo)
        }

        let out = try await Sprigctl.run(["log", "--max", "1", "--json", repo.path])
        #expect(out.exitCode == 0)
        let data = try #require(out.stdout.data(using: .utf8))
        let arr = try #require(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        #expect(arr.count == 1)
    }
}

// MARK: - Agent

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
        var sawMatch = false
        for line in out.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if (obj["kind"] as? String) == "badgeChanged",
               let payload = obj["payload"] as? [String: Any],
               (payload["path"] as? String)?.contains("a.txt") == true,
               (payload["badge"] as? String) == "modified" {
                sawMatch = true
                break
            }
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
        // Clean repo → empty diff on initial refresh → no envelopes.
        // stderr may contain the "# agent: watching ..." status line; the
        // assertion is on stdout only.
        let nonEmptyStdoutLines = out.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count
        #expect(nonEmptyStdoutLines == 0, "expected no envelopes on stdout, got:\n\(out.stdout)")
    }
}
