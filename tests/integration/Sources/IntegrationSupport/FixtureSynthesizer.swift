// FixtureSynthesizer.swift
//
// On-the-fly construction of git repos in known states, for the
// integration tests that wire the M1 → M2 exit gate. Synthesizing in-
// test means the repo is built with the same `git` binary the test will
// query — which is exactly what we want for parser-fidelity testing
// (different git versions can emit subtly different porcelain output).
//
// Per CLAUDE.md: "Never mock the git binary in integration tests. Spawn
// real git against fixture repos." This file is the spawning surface.

import Foundation
import GitCore

/// Builds and tears down isolated git fixtures for integration tests.
///
/// Each call to `make...` returns a fresh, isolated repo under the
/// system temp dir. Callers are responsible for cleanup; ``cleanup(_:)``
/// is a convenience wrapper around `FileManager.removeItem`.
///
/// **Cross-platform.** Pure Foundation + `GitCore.Runner`; runs on
/// macOS, Linux, and Windows. PATH-based git lookup happens inside
/// `Runner`, so the synthesizer picks up whatever `git` is in scope on
/// each platform's CI runner.
public enum FixtureSynthesizer {
    /// Tag a fixture so its temp dir is easy to spot in `/tmp` listings
    /// and diagnostics.
    public static let tempPrefix = "sprig-integration-"

    // MARK: - Setup helpers

    /// Create an empty directory under the system temp dir, namespaced
    /// by `tag` plus a UUID so concurrent tests don't collide.
    public static func makeTempDir(tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(tempPrefix)\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run `git init -b main` plus the minimal config the integration
    /// tests need to commit without environmental git config bleeding
    /// in. Returns a `Runner` pointed at the new repo.
    public static func initRepo(at root: URL) async throws -> Runner {
        let runner = Runner(defaultWorkingDirectory: root)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        return runner
    }

    /// Remove a synthesized fixture. Best-effort; failures are ignored
    /// so test teardown never hides a more interesting assertion.
    public static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Repo state synthesizers

    //
    // Each `make<State>` builds a repo in the named state, with one
    // seed commit (where applicable) so HEAD exists. Tests assert
    // parser output against the documented entry shape these produce.

    /// A repo with a single committed file and no working-tree changes.
    /// porcelain-v2 reports an empty `entries` list.
    public static func makeClean(_ tag: String = "clean") async throws -> (URL, Runner) {
        let dir = try makeTempDir(tag: tag)
        let runner = try await initRepo(at: dir)
        try writeFile("a.txt", "seed\n", under: dir)
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    /// A repo with one worktree-modified-but-not-staged file.
    /// porcelain-v2 reports an `Ordinary` entry with `XY = .M` (index
    /// unmodified, worktree modified).
    public static func makeModified(_ tag: String = "modified") async throws -> (URL, Runner) {
        let (dir, runner) = try await makeClean(tag)
        try writeFile("a.txt", "modified\n", under: dir)
        return (dir, runner)
    }

    /// A repo with one staged change waiting in the index.
    /// porcelain-v2 reports an `Ordinary` entry with `XY = M.` (index
    /// modified, worktree unmodified).
    public static func makeStaged(_ tag: String = "staged") async throws -> (URL, Runner) {
        let (dir, runner) = try await makeClean(tag)
        try writeFile("a.txt", "staged\n", under: dir)
        _ = try await runner.run(["add", "a.txt"])
        return (dir, runner)
    }

    /// A repo with one staged + further-modified file.
    /// porcelain-v2 reports an `Ordinary` entry with `XY = MM`.
    public static func makeStagedAndModified(_ tag: String = "staged-and-modified") async throws -> (URL, Runner) {
        let (dir, runner) = try await makeStaged(tag)
        try writeFile("a.txt", "staged-then-modified\n", under: dir)
        return (dir, runner)
    }

    /// A repo with an untracked file. porcelain-v2 reports `?` entries.
    public static func makeUntracked(_ tag: String = "untracked") async throws -> (URL, Runner) {
        let (dir, runner) = try await makeClean(tag)
        try writeFile("untracked.txt", "not tracked\n", under: dir)
        return (dir, runner)
    }

    /// A repo with a tracked file deleted from the worktree.
    /// porcelain-v2 reports an `Ordinary` entry with `XY = .D`.
    public static func makeDeleted(_ tag: String = "deleted") async throws -> (URL, Runner) {
        let (dir, runner) = try await makeClean(tag)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a.txt"))
        return (dir, runner)
    }

    /// A repo with `.gitignore` matching a file, plus that file present
    /// on disk. porcelain-v2 with `--ignored=traditional` (which we
    /// pass via `--untracked-files=all` ordering) reports `!` entries
    /// only when `--ignored` is requested; default invocation hides
    /// them. We test the default behavior here.
    public static func makeWithGitignore(_ tag: String = "gitignore") async throws -> (URL, Runner) {
        let (dir, runner) = try await makeClean(tag)
        try writeFile(".gitignore", "ignored.log\n", under: dir)
        _ = try await runner.run(["add", ".gitignore"])
        _ = try await runner.run(["commit", "-m", "add gitignore"])
        try writeFile("ignored.log", "should not appear\n", under: dir)
        return (dir, runner)
    }

    /// A repo with an unresolved merge conflict in `a.txt`.
    /// porcelain-v2 reports an `Unmerged` entry.
    public static func makeMergeConflict(_ tag: String = "conflict") async throws -> (URL, Runner) {
        let (dir, runner) = try await makeClean(tag)

        // Branch A modifies a.txt.
        _ = try await runner.run(["checkout", "-b", "feature-a"])
        try writeFile("a.txt", "branch-a-version\n", under: dir)
        _ = try await runner.run(["commit", "-am", "feature-a"])

        // Branch B modifies a.txt differently.
        _ = try await runner.run(["checkout", "main"])
        _ = try await runner.run(["checkout", "-b", "feature-b"])
        try writeFile("a.txt", "branch-b-version\n", under: dir)
        _ = try await runner.run(["commit", "-am", "feature-b"])

        // Merge feature-a into feature-b → conflict. Allow non-zero
        // exit because merge with conflicts exits 1.
        _ = try await runner.run(["merge", "feature-a"], throwOnNonZero: false)
        return (dir, runner)
    }

    /// A repo with a tracked file renamed (staged rename).
    /// porcelain-v2 reports a `Renamed` entry — but only when the
    /// caller passes flags / config that surface renames. We use
    /// `--find-renames` via the porcelain v2 default (status detects
    /// renames automatically when both halves are staged).
    public static func makeRenamed(_ tag: String = "renamed") async throws -> (URL, Runner) {
        let (dir, runner) = try await makeClean(tag)
        _ = try await runner.run(["mv", "a.txt", "b.txt"])
        return (dir, runner)
    }

    // MARK: - File helpers

    /// Write `content` to `relativePath` under `dir`, creating parent
    /// directories as needed. Always writes UTF-8.
    public static func writeFile(_ relativePath: String, _ content: String, under dir: URL) throws {
        let url = dir.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        if parent.path != dir.path {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(content.utf8).write(to: url)
    }
}
