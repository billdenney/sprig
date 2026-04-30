import Foundation
@testable import GitCore
import Testing

/// Branch-state and XY-status integration tests against real git, split
/// off from `PorcelainV2IntegrationTests.swift` to keep both files under
/// SwiftLint's `type_body_length` and `file_length` caps. The helper set
/// is duplicated by design — copy is cheaper than the alternative of
/// pulling them into a shared helper file that both suites would have
/// to agree on.
@Suite("PorcelainV2Parser — branch state and XY codes")
struct PorcelainV2BranchAndXYTests {
    private func runner(at url: URL) -> Runner {
        Runner(defaultWorkingDirectory: url)
    }

    private func mkRepo(_ test: String) throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-porcelain-\(test)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (tmp, runner(at: tmp))
    }

    private func initRepo(_ r: Runner) async throws {
        _ = try await r.run(["init", "-b", "main"])
        _ = try await r.run(["config", "user.email", "test@sprig.app"])
        _ = try await r.run(["config", "user.name", "Sprig Test"])
        _ = try await r.run(["config", "commit.gpgsign", "false"])
    }

    private func parseStatus(_ r: Runner) async throws -> PorcelainV2Status {
        let output = try await r.run([
            "status",
            "--porcelain=v2",
            "--branch",
            "--show-stash",
            "-z",
            "--untracked-files=all"
        ])
        return try PorcelainV2Parser.parse(output.stdout)
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)!.write(to: url)
    }

    /// Filter for the first `Entry.ordinary` matching `path`. Most XY tests
    /// only assert one ordinary entry, but the test repos can also produce
    /// `# branch.*` headers and (in `MM` form) other entries we don't care
    /// about, so we filter explicitly.
    private func extractOrdinary(_ entries: [Entry], path: String) -> Ordinary? {
        for entry in entries {
            if case let .ordinary(ordinary) = entry, ordinary.path == path {
                return ordinary
            }
        }
        return nil
    }

    // MARK: branch state

    @Test("detached HEAD: branch.head is nil after checking out a commit SHA")
    func detachedHeadHeadIsNil() async throws {
        let (tmp, r) = try mkRepo("detached")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("seed\n", to: tmp.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        // Detach HEAD by checking out the commit SHA directly.
        let revOut = try await r.run(["rev-parse", "HEAD"])
        let sha = String(data: revOut.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = try await r.run(["checkout", "--detach", sha])

        let status = try await parseStatus(r)
        #expect(status.branch?.head == nil, "detached HEAD should report head=nil")
        #expect(status.branch?.oid == sha)
    }

    @Test("ahead/behind: branch.ab counts populate when a tracking remote diverges")
    func aheadBehindReflectsLocalAndRemoteDivergence() async throws {
        // Build a parent "remote" repo and clone it; then create divergent
        // commits on each side so `--branch` emits non-zero ahead/behind.
        let upstreamTmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-porcelain-upstream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: upstreamTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: upstreamTmp) }
        let upstream = runner(at: upstreamTmp)
        try await initRepo(upstream)
        try write("base\n", to: upstreamTmp.appendingPathComponent("a.txt"))
        _ = try await upstream.run(["add", "a.txt"])
        _ = try await upstream.run(["commit", "-m", "base"])

        // Clone — gives us a local repo with `origin/main` tracking upstream.
        let cloneTmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-porcelain-clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cloneTmp) }
        let cloneParent = Runner(defaultWorkingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        _ = try await cloneParent.run(["clone", upstreamTmp.path, cloneTmp.path])
        let local = runner(at: cloneTmp)
        _ = try await local.run(["config", "user.email", "test@sprig.app"])
        _ = try await local.run(["config", "user.name", "Sprig Test"])
        _ = try await local.run(["config", "commit.gpgsign", "false"])

        // Diverge: 2 commits ahead locally, 1 commit behind upstream.
        try write("local-1\n", to: cloneTmp.appendingPathComponent("local1.txt"))
        _ = try await local.run(["add", "local1.txt"])
        _ = try await local.run(["commit", "-m", "local 1"])
        try write("local-2\n", to: cloneTmp.appendingPathComponent("local2.txt"))
        _ = try await local.run(["add", "local2.txt"])
        _ = try await local.run(["commit", "-m", "local 2"])

        try write("upstream-1\n", to: upstreamTmp.appendingPathComponent("upstream1.txt"))
        _ = try await upstream.run(["add", "upstream1.txt"])
        _ = try await upstream.run(["commit", "-m", "upstream 1"])

        // Refresh remote-tracking refs so origin/main reflects the new tip.
        _ = try await local.run(["fetch", "origin"])

        let status = try await parseStatus(local)
        #expect(status.branch?.upstream == "origin/main")
        #expect(status.branch?.ahead == 2, "expected 2 local commits ahead of upstream")
        #expect(status.branch?.behind == 1, "expected 1 upstream commit behind local")
    }

    // MARK: XY status combinations

    @Test("staged-then-modified file shows MM (index=M, worktree=M)")
    func stagedThenModifiedShowsMM() async throws {
        let (tmp, r) = try mkRepo("xy-mm")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("v1\n", to: tmp.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        // Stage v2, then dirty the worktree to v3 — index has v2, worktree v3.
        try write("v2\n", to: tmp.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        try write("v3\n", to: tmp.appendingPathComponent("a.txt"))

        let status = try await parseStatus(r)
        let entry = try #require(extractOrdinary(status.entries, path: "a.txt"))
        #expect(entry.xy.index == .modified)
        #expect(entry.xy.worktree == .modified)
    }

    @Test("staged delete shows D. (index=D, worktree=unmodified)")
    func stagedDeleteShowsDDot() async throws {
        let (tmp, r) = try mkRepo("xy-d-dot")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("seed\n", to: tmp.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        _ = try await r.run(["rm", "a.txt"])

        let status = try await parseStatus(r)
        let entry = try #require(extractOrdinary(status.entries, path: "a.txt"))
        #expect(entry.xy.index == .deleted)
        #expect(entry.xy.worktree == .unmodified)
    }

    @Test("worktree-only delete shows .D (index=unmodified, worktree=D)")
    func worktreeDeleteShowsDotD() async throws {
        let (tmp, r) = try mkRepo("xy-dot-d")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("seed\n", to: tmp.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        // Bypass the index — remove from worktree only.
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("a.txt"))

        let status = try await parseStatus(r)
        let entry = try #require(extractOrdinary(status.entries, path: "a.txt"))
        #expect(entry.xy.index == .unmodified)
        #expect(entry.xy.worktree == .deleted)
    }

    @Test("staged-modified-only file shows M. (index=M, worktree=unmodified)")
    func stagedModifiedShowsMDot() async throws {
        let (tmp, r) = try mkRepo("xy-m-dot")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("v1\n", to: tmp.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        try write("v2\n", to: tmp.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])

        let status = try await parseStatus(r)
        let entry = try #require(extractOrdinary(status.entries, path: "a.txt"))
        #expect(entry.xy.index == .modified)
        #expect(entry.xy.worktree == .unmodified)
    }

    // MARK: ignored

    @Test("ignored entries surface when --ignored is requested")
    func ignoredEntriesSurfaceWithIgnoredFlag() async throws {
        let (tmp, r) = try mkRepo("ignored")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("build/\n", to: tmp.appendingPathComponent(".gitignore"))
        _ = try await r.run(["add", ".gitignore"])
        _ = try await r.run(["commit", "-m", "seed"])

        // Create a file under the ignored directory.
        let buildDir = tmp.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try write("artifact\n", to: buildDir.appendingPathComponent("out.o"))

        // Ask git to surface ignored entries (default omits them). The
        // parser itself must round-trip the `!` prefix.
        let output = try await r.run([
            "status",
            "--porcelain=v2",
            "--branch",
            "--show-stash",
            "-z",
            "--untracked-files=all",
            "--ignored"
        ])
        let status = try PorcelainV2Parser.parse(output.stdout)

        let ignored = status.entries.compactMap { entry -> String? in
            if case let .ignored(path) = entry { return path } else { return nil }
        }
        // Recent git surfaces individual ignored *files* (e.g. `build/out.o`)
        // rather than directory-level patterns. Older git used to collapse
        // entire ignored directories into a single trailing-slash entry
        // (`build/`); we accept both shapes since the parser handles them
        // identically — the load-bearing thing is that the `!` prefix
        // round-trips into `Entry.ignored`.
        #expect(
            ignored.contains(where: { $0.hasPrefix("build/") }),
            "expected an ignored entry under build/; got \(ignored)"
        )
    }
}
