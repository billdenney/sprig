// SprigctlCloneTests.swift
//
// `sprigctl clone` end-to-end against a local bare fixture (real
// git, no network — browse's actual forge listing is the one path
// tests never touch; its validation and guidance ARE pinned here).

import Foundation
import Testing

@Suite("sprigctl clone")
struct SprigctlCloneTests {
    /// A bare origin with one commit, plus an empty work area to
    /// clone into.
    private func makeFixture(_ label: String) async throws -> (origin: URL, workArea: URL) {
        let dir = try Sprigctl.mkRepo("clone-\(label)")
        let seed = dir.appendingPathComponent("seed")
        let origin = dir.appendingPathComponent("origin-repo.git")
        let workArea = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workArea, withIntermediateDirectories: true)
        try await Sprigctl.initRepo(at: seed)
        try Sprigctl.write("seed\n", to: seed.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: seed)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: seed)
        try Sprigctl.write("more\n", to: seed.appendingPathComponent("b.txt"))
        try await Sprigctl.spawnGit(["add", "b.txt"], cwd: seed)
        try await Sprigctl.spawnGit(["commit", "-m", "second"], cwd: seed)
        try await Sprigctl.spawnGit(
            ["clone", "--bare", seed.path, origin.path],
            cwd: dir
        )
        return (origin, workArea)
    }

    @Test("clones a URL into an explicit directory")
    func clonesIntoExplicitDirectory() async throws {
        let (origin, workArea) = try await makeFixture("explicit")
        defer { try? FileManager.default.removeItem(at: workArea.deletingLastPathComponent()) }

        let out = try await Sprigctl.run(
            ["clone", origin.path, "picked-name"],
            cwd: workArea
        )

        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Cloned into"))
        let cloned = workArea.appendingPathComponent("picked-name")
        #expect(FileManager.default.fileExists(atPath: cloned.appendingPathComponent(".git").path))
        #expect(FileManager.default.fileExists(atPath: cloned.appendingPathComponent("a.txt").path))
    }

    @Test("the default directory is the repository's name, .git stripped")
    func defaultDirectoryFromURL() async throws {
        let (origin, workArea) = try await makeFixture("default")
        defer { try? FileManager.default.removeItem(at: workArea.deletingLastPathComponent()) }

        let out = try await Sprigctl.run(["clone", origin.path], cwd: workArea)

        #expect(out.exitCode == 0)
        let cloned = workArea.appendingPathComponent("origin-repo")
        #expect(FileManager.default.fileExists(atPath: cloned.appendingPathComponent("a.txt").path))
    }

    @Test("--depth 1 produces a single-commit history")
    func shallowDepth() async throws {
        let (origin, workArea) = try await makeFixture("depth")
        defer { try? FileManager.default.removeItem(at: workArea.deletingLastPathComponent()) }

        // file:// transport — local-path clones ignore --depth.
        let out = try await Sprigctl.run(
            ["clone", "file://\(origin.path)", "shallow", "--depth", "1"],
            cwd: workArea
        )
        #expect(out.exitCode == 0)

        let counter = Process()
        counter.executableURL = try URL(fileURLWithPath: Sprigctl.gitBinaryPath())
        counter.arguments = ["rev-list", "--count", "HEAD"]
        counter.currentDirectoryURL = workArea.appendingPathComponent("shallow")
        let pipe = Pipe()
        counter.standardOutput = pipe
        try counter.run()
        let count = try String(
            data: pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        counter.waitUntilExit()
        #expect(count == "1")
    }

    @Test("a failing clone reports the worded failure and exits 1")
    func failedCloneWorded() async throws {
        let (_, workArea) = try await makeFixture("fail")
        defer { try? FileManager.default.removeItem(at: workArea.deletingLastPathComponent()) }

        let out = try await Sprigctl.run(
            ["clone", workArea.appendingPathComponent("nonexistent.git").path, "target"],
            cwd: workArea
        )
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("clone failed:"))
    }

    @Test("URL and --browse are mutually exclusive; --browse needs --provider")
    func browseValidation() async throws {
        let both = try await Sprigctl.run(["clone", "https://x.invalid/r.git", "--browse"])
        #expect(both.exitCode != 0)
        #expect(both.stderr.contains("not both"))

        let noProvider = try await Sprigctl.run(["clone", "--browse"])
        #expect(noProvider.exitCode != 0)
        #expect(noProvider.stderr.contains("--provider"))

        let neither = try await Sprigctl.run(["clone"])
        #expect(neither.exitCode != 0)
        #expect(neither.stderr.contains("--browse"))
    }

    @Test("--browse without a stored token names both connect paths")
    func browseWithoutTokenGuides() async throws {
        // cwd is a repo whose helper chain is reset + empty, so the
        // token lookup is deterministically nil regardless of any
        // machine-wide credential helper.
        let repo = try Sprigctl.mkRepo("clone-notoken")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try await Sprigctl.spawnGit(["config", "credential.helper", ""], cwd: repo)

        let out = try await Sprigctl.run(
            ["clone", "--browse", "--provider", "github"],
            cwd: repo
        )
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("not connected to github"))
        #expect(out.stderr.contains("sprigctl forge login"))
        #expect(out.stderr.contains("sprigctl credential --set"))
    }
}
