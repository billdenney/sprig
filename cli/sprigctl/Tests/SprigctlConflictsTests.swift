import Foundation
import Testing

// `sprigctl conflicts` end-to-end CLI tests. Lives in its own file so
// neither it nor `SprigctlTests.swift` trips SwiftLint's `file_length`
// cap as the surface grows.

@Suite("sprigctl conflicts")
struct SprigctlConflictsTests {
    @Test("conflicts --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["conflicts", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.lowercased().contains("conflicts"))
        #expect(out.stdout.contains("--list"))
        #expect(out.stdout.contains("--show"))
    }

    @Test("conflicts without --list or --show errors with a helpful message")
    func errorsWithoutMode() async throws {
        let out = try await Sprigctl.run(["conflicts"])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("--list") || out.stderr.contains("--show"))
    }

    @Test("conflicts --list and --show are mutually exclusive")
    func mutuallyExclusiveFlags() async throws {
        let out = try await Sprigctl.run(["conflicts", "--list", "--show"])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("mutually exclusive"))
    }

    @Test("conflicts --auto-resolve and --show are mutually exclusive")
    func autoResolveAndShowExclusive() async throws {
        let out = try await Sprigctl.run(["conflicts", "--auto-resolve", "--show", "/tmp/foo"])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("mutually exclusive"))
    }

    @Test("--whitespace without --auto-resolve is rejected")
    func whitespaceRequiresAutoResolve() async throws {
        let dir = try Sprigctl.mkRepo("conflicts-whitespace-bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Sprigctl.write("clean\n", to: dir.appendingPathComponent("a.txt"))

        let out = try await Sprigctl.run([
            "conflicts", "--show", "--whitespace", dir.appendingPathComponent("a.txt").path
        ])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("--whitespace") || out.stderr.contains("--auto-resolve"))
    }

    // MARK: - --list

    @Test("conflicts --list on a clean repo prints nothing on stdout")
    func listOnCleanRepo() async throws {
        let repo = try Sprigctl.mkRepo("conflicts-clean")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)

        let out = try await Sprigctl.run(["conflicts", "--list", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(out.stderr.contains("no unmerged paths"))
    }

    @Test("conflicts --list surfaces a real merge conflict")
    func listOnRepoWithRealConflict() async throws {
        let repo = try Sprigctl.mkRepo("conflicts-real")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await makeRealMergeConflict(at: repo)

        let out = try await Sprigctl.run(["conflicts", "--list", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("a.txt"))
        // The conflict has exactly one region.
        #expect(out.stdout.contains("1 region"))
    }

    @Test("conflicts --list --json emits a parseable array")
    func listJSON() async throws {
        let repo = try Sprigctl.mkRepo("conflicts-json")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await makeRealMergeConflict(at: repo)

        let out = try await Sprigctl.run(["conflicts", "--list", "--json", repo.path])
        #expect(out.exitCode == 0)
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let array = try #require(parsed as? [[String: Any]])
        #expect(array.count == 1)
        #expect(array[0]["path"] as? String == "a.txt")
        #expect(array[0]["regions"] as? Int == 1)
    }

    // MARK: - --show

    @Test("conflicts --show requires a file path argument")
    func showRequiresPath() async throws {
        let out = try await Sprigctl.run(["conflicts", "--show"])
        #expect(out.exitCode != 0)
        // The error may come from argparse missing the positional or
        // from our explicit ValidationError; either is acceptable.
        #expect(out.stderr.contains("file") || out.stderr.contains("path") || out.stderr.contains("argument"))
    }

    @Test("conflicts --show on a file with no markers prints nothing on stdout")
    func showOnCleanFile() async throws {
        let dir = try Sprigctl.mkRepo("conflicts-show-clean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clean.txt")
        try Sprigctl.write("alpha\nbeta\ngamma\n", to: file)

        let out = try await Sprigctl.run(["conflicts", "--show", file.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(out.stderr.contains("no conflict regions"))
    }

    @Test("conflicts --show prints region details for a file with markers")
    func showPrintsRegionDetails() async throws {
        let dir = try Sprigctl.mkRepo("conflicts-show-real")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("with-conflict.txt")
        try Sprigctl.write(
            """
            before
            <<<<<<< HEAD
            ours-1
            ours-2
            =======
            theirs-1
            >>>>>>> feature
            after
            """,
            to: file
        )

        let out = try await Sprigctl.run(["conflicts", "--show", file.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("region 1"))
        #expect(out.stdout.contains("ours=HEAD"))
        #expect(out.stdout.contains("theirs=feature"))
        #expect(out.stdout.contains("ours-1"))
        #expect(out.stdout.contains("theirs-1"))
    }

    @Test("conflicts --show --json emits a parseable region array")
    func showJSON() async throws {
        let dir = try Sprigctl.mkRepo("conflicts-show-json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("with-conflict.txt")
        try Sprigctl.write(
            """
            <<<<<<< HEAD
            ours
            =======
            theirs
            >>>>>>> feature
            """,
            to: file
        )

        let out = try await Sprigctl.run(["conflicts", "--show", "--json", file.path])
        #expect(out.exitCode == 0)
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let array = try #require(parsed as? [[String: Any]])
        #expect(array.count == 1)
        let region = array[0]
        #expect(region["oursLabel"] as? String == "HEAD")
        #expect(region["theirsLabel"] as? String == "feature")
        #expect(region["startLine"] as? Int == 1)
        #expect(region["endLine"] as? Int == 5)
    }

    // MARK: - Helpers

    /// Create a repo, branch, and force a real merge conflict on
    /// `a.txt`. After this returns, the repo is in mid-merge state
    /// with `a.txt` carrying conflict markers and `git status
    /// --porcelain=v2` reporting it as unmerged.
    private func makeRealMergeConflict(at repo: URL) async throws {
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("v1\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)

        // Diverge: branch + edit, switch back to main + conflicting edit.
        try await Sprigctl.spawnGit(["checkout", "-b", "feature"], cwd: repo)
        try Sprigctl.write("from-feature\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["commit", "-am", "feature"], cwd: repo)

        try await Sprigctl.spawnGit(["checkout", "main"], cwd: repo)
        try Sprigctl.write("from-main\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["commit", "-am", "main"], cwd: repo)

        // Merge — expected to fail with a conflict. We don't await
        // the failure; just leave the repo in mid-merge state.
        let mergeProc = Process()
        mergeProc.executableURL = try URL(fileURLWithPath: Sprigctl.gitBinaryPath())
        mergeProc.arguments = ["merge", "feature"]
        mergeProc.currentDirectoryURL = repo
        mergeProc.standardOutput = FileHandle.nullDevice
        mergeProc.standardError = FileHandle.nullDevice
        try await mergeProc.runAndAwaitExit()
        // mergeProc.terminationStatus is non-zero — that's expected.
    }
}
