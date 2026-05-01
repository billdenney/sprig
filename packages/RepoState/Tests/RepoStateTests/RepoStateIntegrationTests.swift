import Foundation
import GitCore
@testable import RepoState
import Testing

/// End-to-end tests that drive `RepoStateStore` through the full
/// production chain: spawn real git → run `git status --porcelain=v2
/// -z` → `PorcelainV2Parser.parse` → `RepoStateStore.apply` → query
/// badges. The unit tests in `RepoStateStoreTests` already cover the
/// store with synthesized `PorcelainV2Status` values; this suite
/// catches misalignment between what real git emits and what the
/// store does with it.
///
/// Each test mirrors a scenario from `PorcelainV2IntegrationTests` /
/// `PorcelainV2BranchAndXYTests` but checks the final badge resolution
/// rather than the parsed structure.
@Suite("RepoStateStore — end-to-end against real git")
struct RepoStateIntegrationTests {
    private func runner(at url: URL) -> Runner {
        Runner(defaultWorkingDirectory: url)
    }

    private func mkRepo(_ test: String) throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-repostate-e2e-\(test)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (tmp.standardized, runner(at: tmp))
    }

    private func initRepo(_ r: Runner) async throws {
        _ = try await r.run(["init", "-b", "main"])
        _ = try await r.run(["config", "user.email", "test@sprig.app"])
        _ = try await r.run(["config", "user.name", "Sprig Test"])
        _ = try await r.run(["config", "commit.gpgsign", "false"])
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    /// Run `git status` against the runner's working tree, parse the
    /// output, and apply it to a fresh `RepoStateStore`. Returns the
    /// store so the test can query badges.
    private func snapshotStore(repoRoot: URL, runner: Runner) async throws -> RepoStateStore {
        let output = try await runner.run([
            "status",
            "--porcelain=v2",
            "--branch",
            "--show-stash",
            "-z",
            "--untracked-files=all",
            "--ignored"
        ])
        let status = try PorcelainV2Parser.parse(output.stdout)
        let store = RepoStateStore(repoRoot: repoRoot)
        await store.apply(status)
        return store
    }

    // MARK: clean / no-badge cases

    @Test("clean repo after initial commit: tracked files have no badge")
    func cleanTrackedFilesUnbadged() async throws {
        let (root, r) = try mkRepo("clean")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        try write("hello\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])

        let store = try await snapshotStore(repoRoot: root, runner: r)
        // Clean files don't appear in porcelain output, so the trie is
        // empty and the badge query returns nil.
        #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == nil)
        #expect(await store.entryCount() == 0)
        // Branch metadata DOES come through the headers.
        #expect(await store.branch()?.head == "main")
    }

    // MARK: file-state badges

    @Test("worktree-modified file (.M) → .modified badge")
    func worktreeModifiedBadge() async throws {
        let (root, r) = try mkRepo("worktree-modified")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        try write("v1\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        try write("v2\n", to: root.appendingPathComponent("a.txt"))

        let store = try await snapshotStore(repoRoot: root, runner: r)
        #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == .modified)
    }

    @Test("staged-only modify (M.) → .staged badge")
    func stagedOnlyBadge() async throws {
        let (root, r) = try mkRepo("staged-only")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        try write("v1\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        try write("v2\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])

        let store = try await snapshotStore(repoRoot: root, runner: r)
        #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == .staged)
    }

    @Test("staged + worktree modified (MM) → .modified (worktree wins)")
    func mmBadge() async throws {
        let (root, r) = try mkRepo("mm")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        try write("v1\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        try write("v2\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        try write("v3\n", to: root.appendingPathComponent("a.txt"))

        let store = try await snapshotStore(repoRoot: root, runner: r)
        #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == .modified)
    }

    @Test("staged-add (A.) → .added badge")
    func stagedAddBadge() async throws {
        let (root, r) = try mkRepo("staged-add")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        // A file that's only ever existed staged — never committed yet.
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])

        let store = try await snapshotStore(repoRoot: root, runner: r)
        #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == .added)
    }

    @Test("untracked file → .untracked badge")
    func untrackedBadge() async throws {
        let (root, r) = try mkRepo("untracked")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        try write("not yet\n", to: root.appendingPathComponent("new.txt"))

        let store = try await snapshotStore(repoRoot: root, runner: r)
        #expect(await store.badge(for: root.appendingPathComponent("new.txt")) == .untracked)
    }

    // MARK: conflict (always wins)

    @Test("merge conflict → .conflict badge")
    func conflictBadge() async throws {
        let (root, r) = try mkRepo("conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        // Set up a conflicting merge: branch off, change c.txt on
        // both branches in incompatible ways, merge.
        try write("base\n", to: root.appendingPathComponent("c.txt"))
        _ = try await r.run(["add", "c.txt"])
        _ = try await r.run(["commit", "-m", "base"])

        _ = try await r.run(["checkout", "-b", "feature"])
        try write("feature side\n", to: root.appendingPathComponent("c.txt"))
        _ = try await r.run(["add", "c.txt"])
        _ = try await r.run(["commit", "-m", "feature change"])

        _ = try await r.run(["checkout", "main"])
        try write("main side\n", to: root.appendingPathComponent("c.txt"))
        _ = try await r.run(["add", "c.txt"])
        _ = try await r.run(["commit", "-m", "main change"])

        // Force a conflict; merge will exit non-zero, which we ignore.
        _ = try? await r.run(["merge", "feature"], throwOnNonZero: false)

        let store = try await snapshotStore(repoRoot: root, runner: r)
        #expect(await store.badge(for: root.appendingPathComponent("c.txt")) == .conflict)
    }

    // MARK: ignored directory inheritance (the load-bearing trie case)

    @Test("ignored directory propagates `.ignored` to children via nearest-ancestor lookup")
    func ignoredDirectoryInheritance() async throws {
        let (root, r) = try mkRepo("ignored-dir")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        try write("build/\n", to: root.appendingPathComponent(".gitignore"))
        _ = try await r.run(["add", ".gitignore"])
        _ = try await r.run(["commit", "-m", "seed"])

        // Create files inside the ignored directory.
        let buildDir = root.appendingPathComponent("build")
        let nestedDir = buildDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try write("artifact\n", to: buildDir.appendingPathComponent("out.o"))
        try write("nested\n", to: nestedDir.appendingPathComponent("deep.o"))

        let store = try await snapshotStore(repoRoot: root, runner: r)
        // git surfaces individual ignored files (recent versions) or
        // the directory itself (older versions). Either way, the
        // PathTrie's nearest-ancestor walk should resolve all paths
        // under build/ as `.ignored`.
        #expect(await store.badge(for: buildDir.appendingPathComponent("out.o")) == .ignored)
        #expect(
            await store.badge(for: buildDir.appendingPathComponent("sub").appendingPathComponent("deep.o"))
                == .ignored
        )
    }

    // MARK: branch metadata

    @Test("detached HEAD: branch.head is nil after checking out a SHA")
    func detachedHead() async throws {
        let (root, r) = try mkRepo("detached")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        let revOut = try await r.run(["rev-parse", "HEAD"])
        let sha = String(data: revOut.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = try await r.run(["checkout", "--detach", sha])

        let store = try await snapshotStore(repoRoot: root, runner: r)
        #expect(await store.branch()?.head == nil, "detached HEAD should report head=nil")
        #expect(await store.branch()?.oid == sha)
    }

    // MARK: snapshot replace semantics across two real-git refreshes

    @Test("re-applying after a worktree change replaces the prior snapshot")
    func snapshotReplaceAcrossRefreshes() async throws {
        let (root, r) = try mkRepo("replace")
        defer { try? FileManager.default.removeItem(at: root) }
        try await initRepo(r)
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])

        // First snapshot: untracked b.txt.
        try write("new\n", to: root.appendingPathComponent("b.txt"))
        let store = try await snapshotStore(repoRoot: root, runner: r)
        #expect(await store.badge(for: root.appendingPathComponent("b.txt")) == .untracked)

        // Stage b.txt, then re-snapshot. Old `.untracked` badge for
        // b.txt should be replaced by `.added`.
        _ = try await r.run(["add", "b.txt"])
        let output2 = try await r.run([
            "status",
            "--porcelain=v2",
            "--branch",
            "--show-stash",
            "-z",
            "--untracked-files=all"
        ])
        let status2 = try PorcelainV2Parser.parse(output2.stdout)
        await store.apply(status2)

        #expect(await store.badge(for: root.appendingPathComponent("b.txt")) == .added)
        // a.txt is still clean → no badge.
        #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == nil)
    }
}
