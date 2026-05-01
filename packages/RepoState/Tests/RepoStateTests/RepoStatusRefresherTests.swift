import Foundation
import GitCore
@testable import RepoState
import Testing

/// End-to-end tests for `RepoStatusRefresher` against real git: the
/// refresher composes Runner + PorcelainV2Parser + GitMetadataPaths
/// + RepoStateStore, so the integration test is the right place to
/// catch wiring regressions.
@Suite("RepoStatusRefresher — bridges Runner output → RepoStateStore")
struct RepoStatusRefresherTests {
    private func mkRepo(_ test: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-refresh-\(test)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let r = Runner(defaultWorkingDirectory: tmp)
        _ = try await r.run(["init", "-b", "main"])
        _ = try await r.run(["config", "user.email", "test@sprig.app"])
        _ = try await r.run(["config", "user.name", "Sprig Test"])
        _ = try await r.run(["config", "commit.gpgsign", "false"])
        return (tmp, r)
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    // MARK: applied path

    @Test("refresh applies a clean snapshot — branch info captured, no entries")
    func refreshAppliesCleanSnapshot() async throws {
        let (root, r) = try await mkRepo("clean")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])

        let store = RepoStateStore(repoRoot: root)
        let refresher = RepoStatusRefresher(store: store)
        let outcome = await refresher.refresh()

        switch outcome {
        case let .applied(entryCount):
            #expect(entryCount == 0, "tracked-clean files don't appear in porcelain output")
        default:
            Issue.record("expected .applied, got \(outcome)")
        }
        #expect(await store.branch()?.head == "main")
    }

    @Test("refresh against a dirty worktree populates badges")
    func refreshAppliesDirtySnapshot() async throws {
        let (root, r) = try await mkRepo("dirty")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("v1\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        try write("v2\n", to: root.appendingPathComponent("a.txt"))
        try write("new\n", to: root.appendingPathComponent("b.txt"))

        let store = RepoStateStore(repoRoot: root)
        let refresher = RepoStatusRefresher(store: store)
        let outcome = await refresher.refresh()

        guard case let .applied(entryCount) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(entryCount == 2, "one modified, one untracked")
        #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == .modified)
        #expect(await store.badge(for: root.appendingPathComponent("b.txt")) == .untracked)
    }

    @Test("refreshing twice replaces the prior snapshot (last-wins)")
    func refreshReplacesPrior() async throws {
        let (root, r) = try await mkRepo("replace")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])

        let store = RepoStateStore(repoRoot: root)
        let refresher = RepoStatusRefresher(store: store)

        // First snapshot: untracked b.txt.
        try write("new\n", to: root.appendingPathComponent("b.txt"))
        _ = await refresher.refresh()
        #expect(await store.badge(for: root.appendingPathComponent("b.txt")) == .untracked)

        // Stage b.txt, refresh again. b.txt's badge changes from
        // .untracked to .added, and any prior state is replaced.
        _ = try await r.run(["add", "b.txt"])
        _ = await refresher.refresh()
        #expect(await store.badge(for: root.appendingPathComponent("b.txt")) == .added)
        #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == nil)
    }

    // MARK: deferred path (ADR 0056 + R15-F-defer)

    @Test("refresh defers when index.lock exists (mid-write deferral)")
    func refreshDefersOnIndexLock() async throws {
        let (root, r) = try await mkRepo("inflight")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])

        // Simulate an in-flight git op by manually creating index.lock.
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let indexLock = gitDir.appendingPathComponent("index.lock")
        try Data().write(to: indexLock)
        defer { try? FileManager.default.removeItem(at: indexLock) }

        let store = RepoStateStore(repoRoot: root)
        let refresher = RepoStatusRefresher(store: store)
        let outcome = await refresher.refresh()

        switch outcome {
        case let .deferred(reason):
            #expect(reason == .gitOperationInFlight)
        default:
            Issue.record("expected .deferred(.gitOperationInFlight), got \(outcome)")
        }
        // Store should be empty — we never invoked git.
        #expect(await store.entryCount() == 0)
        #expect(await store.branch() == nil)
    }

    @Test("refresh resumes successfully once the lock disappears")
    func refreshResumesAfterLockClears() async throws {
        let (root, r) = try await mkRepo("resume")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        try write("dirty\n", to: root.appendingPathComponent("a.txt"))

        let store = RepoStateStore(repoRoot: root)
        let refresher = RepoStatusRefresher(store: store)

        // First refresh: defer via fake lock.
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let indexLock = gitDir.appendingPathComponent("index.lock")
        try Data().write(to: indexLock)
        let firstOutcome = await refresher.refresh()
        if case .deferred = firstOutcome {} else {
            Issue.record("expected first refresh to defer, got \(firstOutcome)")
        }

        // Lock clears; next refresh applies.
        try FileManager.default.removeItem(at: indexLock)
        let secondOutcome = await refresher.refresh()
        if case let .applied(entryCount) = secondOutcome {
            #expect(entryCount == 1)
            #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == .modified)
        } else {
            Issue.record("expected second refresh to apply, got \(secondOutcome)")
        }
    }

    // MARK: failed path

    @Test("refresh against a non-repo returns .failed(GitError.nonZeroExit)")
    func refreshOnNonRepoFails() async throws {
        let nonRepo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-refresh-nonrepo-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepo) }

        let store = RepoStateStore(repoRoot: nonRepo)
        let refresher = RepoStatusRefresher(store: store)
        let outcome = await refresher.refresh()

        switch outcome {
        case let .failed(error):
            // GitError.nonZeroExit is expected — git status against a
            // non-repo returns 128 with "fatal: not a git repository."
            #expect(String(describing: error).contains("nonZeroExit") || error is GitError)
        default:
            Issue.record("expected .failed, got \(outcome)")
        }
    }

    // MARK: branch info round-trips

    @Test("refresh captures detached-HEAD state into branch info")
    func refreshCapturesDetachedHead() async throws {
        let (root, r) = try await mkRepo("detached")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("seed\n", to: root.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        let revOut = try await r.run(["rev-parse", "HEAD"])
        let sha = String(data: revOut.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = try await r.run(["checkout", "--detach", sha])

        let store = RepoStateStore(repoRoot: root)
        let refresher = RepoStatusRefresher(store: store)
        _ = await refresher.refresh()

        #expect(await store.branch()?.head == nil, "detached HEAD reports head=nil")
        #expect(await store.branch()?.oid == sha)
    }
}
