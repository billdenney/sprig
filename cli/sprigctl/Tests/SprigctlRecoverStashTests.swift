import Foundation
import Testing

/// ADR 0079 — the stash-aware Recover restore path. Split from
/// `SprigctlRecoverTests` to stay under the file-length limit. These
/// pin that a stash-drop safety copy (which points at a stash COMMIT,
/// not a repo state) is restored with `git stash store`, never the
/// `reset --hard` every other op uses — including the `-N` uniquified
/// ref shape introduced by the same-second uniquifier (ADR 0033,
/// 2026-06-18 amendment).
@Suite("sprigctl recover — stash-aware restore")
struct SprigctlRecoverStashTests {
    @Test("restore of a stash-drop safety copy puts the entry back in the stash list")
    func restoreStashDropStoresEntry() async throws {
        let repo = try Sprigctl.mkRepo("recover-stashdrop")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)

        // The ADR 0079 dropKeepingSafetyCopy sequence, spelled in raw
        // git: stash an edit, snapshot the stash COMMIT, drop it.
        try Sprigctl.write("wip\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["stash", "push", "-m", "wip work"], cwd: repo)
        let stashSHA = try await readRefSHA("refs/stash", in: repo)
        let snapshotRef = "refs/sprig/snapshots/20260506T040000Z/stash-drop"
        try await Sprigctl.spawnGit(["update-ref", snapshotRef, stashSHA], cwd: repo)
        try await Sprigctl.spawnGit(["stash", "drop"], cwd: repo)
        let headBefore = try await readHEAD(in: repo)

        let out = try await Sprigctl.run([
            "recover",
            "--restore", snapshotRef,
            repo.path
        ])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Restored stash entry from \(snapshotRef)"))
        #expect(out.stdout.contains("stash@{0}"))

        // The entry is back under its original identity; HEAD never
        // moved (a stash-drop restore must not reset the worktree).
        let restoredSHA = try await readRefSHA("refs/stash", in: repo)
        #expect(restoredSHA == stashSHA)
        let headAfter = try await readHEAD(in: repo)
        #expect(headAfter == headBefore)
    }

    @Test("restore of a uniquified stash-drop-2 safety copy also stores the entry (never reset --hard)")
    func restoreUniquifiedStashDropStoresEntry() async throws {
        let repo = try Sprigctl.mkRepo("recover-stashdrop2")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await seed(repo: repo)

        // A same-second second stash-drop is minted under the `-2`
        // uniquifier (createSnapshot's collision handling). The restore
        // must classify it by op FAMILY and still route to `stash store`,
        // not the destructive `reset --hard` every non-stash op uses.
        try Sprigctl.write("wip\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["stash", "push", "-m", "wip work"], cwd: repo)
        let stashSHA = try await readRefSHA("refs/stash", in: repo)
        let snapshotRef = "refs/sprig/snapshots/20260506T040000Z/stash-drop-2"
        try await Sprigctl.spawnGit(["update-ref", snapshotRef, stashSHA], cwd: repo)
        try await Sprigctl.spawnGit(["stash", "drop"], cwd: repo)
        let headBefore = try await readHEAD(in: repo)

        let out = try await Sprigctl.run([
            "recover",
            "--restore", snapshotRef,
            repo.path
        ])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Restored stash entry from \(snapshotRef)"))
        #expect(out.stdout.contains("stash@{0}"))

        // The entry is back; HEAD never moved (the bug the uniquifier
        // exposed would have reset HEAD onto the stash commit instead).
        let restoredSHA = try await readRefSHA("refs/stash", in: repo)
        #expect(restoredSHA == stashSHA)
        let headAfter = try await readHEAD(in: repo)
        #expect(headAfter == headBefore, "a stash-drop restore must never reset HEAD")
    }

    // MARK: - Helpers (mirror the private helpers in SprigctlRecoverTests)

    private func seed(repo: URL) async throws {
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("a.txt"))
        try await Sprigctl.spawnGit(["add", "a.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)
    }

    private func readHEAD(in repo: URL) async throws -> String {
        try await readRefSHA("HEAD", in: repo)
    }

    private func readRefSHA(_ ref: String, in repo: URL) async throws -> String {
        let process = Process()
        process.executableURL = try URL(fileURLWithPath: Sprigctl.gitBinaryPath())
        process.arguments = ["rev-parse", ref]
        process.currentDirectoryURL = repo
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
