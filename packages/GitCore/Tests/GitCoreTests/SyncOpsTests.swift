// SyncOpsTests.swift
//
// ADR 0068 auto-sync primitives against real git (never mocked, per
// CLAUDE.md). Fixture shape for every test: a bare "origin" repo plus
// two clones — `publisher` advances origin, `subscriber` is the repo
// under test.
//
// The track-string parser also gets direct unit coverage (no fixture)
// because its inputs ("[ahead 1, behind 2]" etc.) are cheap to
// enumerate exhaustively.

import Foundation
@testable import GitCore
import Testing

@Suite("SyncOps — track-string + sync-state parsing (pure)")
struct SyncStateParsingTests {
    @Test("parseSyncStates decodes a representative for-each-ref buffer")
    func parseRepresentativeBuffer() throws {
        let sha1 = String(repeating: "1", count: 40)
        let sha2 = String(repeating: "2", count: 40)
        let lines = [
            "main\t\(sha1)\trefs/remotes/origin/main\torigin/main\t[behind 2]\t*",
            "feature\t\(sha2)\trefs/remotes/origin/feature\torigin/feature\t[ahead 1, behind 3]\t ",
            "local-only\t\(sha2)\t\t\t\t ",
            "orphan\t\(sha1)\trefs/remotes/origin/gone-branch\torigin/gone-branch\t[gone]\t "
        ].joined(separator: "\n")

        let states = try SyncOps.parseSyncStates(Data(lines.utf8))
        #expect(states.count == 4)

        #expect(states[0].name == "main")
        #expect(states[0].behind == 2)
        #expect(states[0].ahead == 0)
        #expect(states[0].isCurrent)
        #expect(states[0].upstreamFullRef == "refs/remotes/origin/main")

        #expect(states[1].ahead == 1)
        #expect(states[1].behind == 3)
        #expect(!states[1].isCurrent)

        #expect(states[2].upstreamFullRef == nil)
        #expect(states[2].upstreamShort == nil)
        #expect(!states[2].upstreamGone)

        #expect(states[3].upstreamGone)
    }

    @Test("malformed entry (wrong field count) throws parseFailure")
    func malformedEntryThrows() {
        let bad = Data("main\tonly-two-fields\n".utf8)
        #expect(throws: GitError.self) {
            try SyncOps.parseSyncStates(bad)
        }
    }
}

// `.serialized`: each test builds a bare-origin + two-clone fixture
// and runs pushes — parallel execution multiplies peak git-spawn +
// filesystem churn, which on the Windows VM starves *other* suites'
// atomic writes into sharing-violation retry storms (see
// cross-platform-quirks E1/E2). Serial keeps this suite's load flat.
@Suite("SyncOps — fetch + fast-forward against real git", .serialized)
struct SyncOpsRealGitTests {
    /// Bare origin + publisher/subscriber clones, fully configured.
    private struct Fixture {
        let root: URL
        let origin: URL
        let publisher: URL
        let subscriber: URL
    }

    private func makeFixture(_ label: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-syncops-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootRunner = Runner(defaultWorkingDirectory: root)

        let origin = root.appendingPathComponent("origin.git")
        _ = try await rootRunner.run(["init", "--bare", "-b", "main", origin.path])

        let publisher = root.appendingPathComponent("publisher")
        _ = try await rootRunner.run(["clone", origin.path, publisher.path])
        try await configureIdentity(at: publisher)

        // Seed an initial commit so the subscriber clone has history.
        try await commitFile(named: "seed.txt", content: "seed\n", message: "seed", at: publisher)
        _ = try await Runner(defaultWorkingDirectory: publisher).run(["push", "origin", "main"])

        let subscriber = root.appendingPathComponent("subscriber")
        _ = try await rootRunner.run(["clone", origin.path, subscriber.path])
        try await configureIdentity(at: subscriber)

        return Fixture(root: root, origin: origin, publisher: publisher, subscriber: subscriber)
    }

    private func configureIdentity(at repo: URL) async throws {
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
    }

    private func commitFile(
        named name: String,
        content: String,
        message: String,
        at repo: URL
    ) async throws {
        try Data(content.utf8).write(to: repo.appendingPathComponent(name))
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["add", name])
        _ = try await runner.run(["commit", "-m", message])
    }

    private func publishNewCommit(named name: String, _ fixture: Fixture) async throws {
        try await commitFile(
            named: name,
            content: "\(name)\n",
            message: "add \(name)",
            at: fixture.publisher
        )
        _ = try await Runner(defaultWorkingDirectory: fixture.publisher)
            .run(["push", "origin", "main"])
    }

    @Test("fetchAll advances the remote-tracking ref without touching local branches")
    func fetchAllAdvancesTrackingRef() async throws {
        let fixture = try await makeFixture("fetch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await publishNewCommit(named: "second.txt", fixture)

        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)
        let sync = SyncOps(runner: runner)
        let before = try await sync.branchSyncStates()
        #expect(before.first?.behind == 0) // not yet fetched

        try await sync.fetchAll()

        let after = try await sync.branchSyncStates()
        let main = try #require(after.first { $0.name == "main" })
        #expect(main.behind == 1)
        #expect(main.ahead == 0)
        #expect(main.isCurrent)
        // Local branch itself untouched by fetch.
        #expect(main.sha == before.first?.sha)
    }

    @Test("fast-forwards the clean checked-out branch and updates the working directory")
    func fastForwardCurrentClean() async throws {
        let fixture = try await makeFixture("ffcur")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await publishNewCommit(named: "incoming.txt", fixture)

        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))
        try await sync.fetchAll()
        let results = try await sync.fastForwardLocalBranches()

        #expect(results.count == 1)
        guard case let .fastForwarded(from, to) = results[0].outcome else {
            Issue.record("expected fastForwarded, got \(results[0].outcome)")
            return
        }
        #expect(from != to)
        // Working directory got the new file (the whole point of the
        // ADR 0068 "local directory kept up to date" option).
        let landed = fixture.subscriber.appendingPathComponent("incoming.txt")
        #expect(FileManager.default.fileExists(atPath: landed.path))
    }

    @Test("dirty checked-out branch is skipped (tracked modification)")
    func dirtyWorktreeSkipped() async throws {
        let fixture = try await makeFixture("dirty")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await publishNewCommit(named: "incoming.txt", fixture)

        // Dirty the subscriber: modify the tracked seed file.
        try Data("locally modified\n".utf8)
            .write(to: fixture.subscriber.appendingPathComponent("seed.txt"))

        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))
        try await sync.fetchAll()
        let results = try await sync.fastForwardLocalBranches()

        #expect(results.count == 1)
        #expect(results[0].outcome == .skippedDirtyWorktree)
        // And the branch really didn't move.
        let states = try await sync.branchSyncStates()
        #expect(states[0].behind == 1)
    }

    @Test("untracked-only worktree still fast-forwards (untracked is not dirty)")
    func untrackedOnlyStillFastForwards() async throws {
        let fixture = try await makeFixture("untracked")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await publishNewCommit(named: "incoming.txt", fixture)

        try Data("scratch\n".utf8)
            .write(to: fixture.subscriber.appendingPathComponent("notes.local"))

        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))
        try await sync.fetchAll()
        let results = try await sync.fastForwardLocalBranches()

        guard case .fastForwarded = results[0].outcome else {
            Issue.record("expected fastForwarded, got \(results[0].outcome)")
            return
        }
        // The untracked file survived.
        let kept = fixture.subscriber.appendingPathComponent("notes.local")
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test("non-current branch fast-forwards ref-only via fetch-dot")
    func nonCurrentBranchRefOnly() async throws {
        let fixture = try await makeFixture("refonly")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Park the subscriber on a side branch so `main` is not
        // checked out, then advance origin/main.
        let subRunner = Runner(defaultWorkingDirectory: fixture.subscriber)
        _ = try await subRunner.run(["switch", "-c", "parked"])
        try await publishNewCommit(named: "incoming.txt", fixture)

        let sync = SyncOps(runner: subRunner)
        try await sync.fetchAll()
        let results = try await sync.fastForwardLocalBranches()

        let main = try #require(results.first { $0.branch == "main" })
        guard case let .fastForwarded(_, to) = main.outcome else {
            Issue.record("expected main fastForwarded, got \(main.outcome)")
            return
        }
        // The local main ref now equals origin/main…
        let resolved = try await subRunner.run(["rev-parse", "refs/heads/main"])
        let tracking = try await subRunner.run(["rev-parse", "refs/remotes/origin/main"])
        #expect(resolved.stdoutString == tracking.stdoutString)
        #expect(to == tracking.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
        // …and the working directory (parked branch) did NOT change.
        let untouched = fixture.subscriber.appendingPathComponent("incoming.txt")
        #expect(!FileManager.default.fileExists(atPath: untouched.path))
        // The parked branch has no upstream → typed skip, no mutation.
        let parked = try #require(results.first { $0.branch == "parked" })
        #expect(parked.outcome == .noUpstream)
    }

    @Test("diverged branch is reported, never merged")
    func divergedSkipped() async throws {
        let fixture = try await makeFixture("diverged")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Local commit on subscriber/main + different commit on origin.
        try await commitFile(
            named: "local.txt",
            content: "local\n",
            message: "local work",
            at: fixture.subscriber
        )
        try await publishNewCommit(named: "remote.txt", fixture)

        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))
        try await sync.fetchAll()
        let results = try await sync.fastForwardLocalBranches()

        #expect(results[0].outcome == .diverged(ahead: 1, behind: 1))
    }

    @Test("ahead-only branch reports aheadOnly and stays put")
    func aheadOnlyReported() async throws {
        let fixture = try await makeFixture("ahead")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await commitFile(
            named: "unpushed.txt",
            content: "unpushed\n",
            message: "unpushed work",
            at: fixture.subscriber
        )

        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))
        try await sync.fetchAll()
        let results = try await sync.fastForwardLocalBranches()

        #expect(results[0].outcome == .aheadOnly(ahead: 1))
    }

    @Test("upstream deleted on the remote reports upstreamGone after prune")
    func upstreamGoneReported() async throws {
        let fixture = try await makeFixture("gone")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Publish a side branch, track it from the subscriber, then
        // delete it on origin.
        let pubRunner = Runner(defaultWorkingDirectory: fixture.publisher)
        _ = try await pubRunner.run(["switch", "-c", "ephemeral"])
        _ = try await pubRunner.run(["push", "-u", "origin", "ephemeral"])

        let subRunner = Runner(defaultWorkingDirectory: fixture.subscriber)
        let sync = SyncOps(runner: subRunner)
        try await sync.fetchAll()
        _ = try await subRunner.run(["switch", "-c", "ephemeral", "origin/ephemeral"])
        _ = try await subRunner.run(["switch", "main"])

        _ = try await pubRunner.run(["push", "origin", "--delete", "ephemeral"])
        try await sync.fetchAll() // --prune drops the tracking ref

        let results = try await sync.fastForwardLocalBranches()
        let ephemeral = try #require(results.first { $0.branch == "ephemeral" })
        #expect(ephemeral.outcome == .upstreamGone)
    }
}
