// SyncOpsPushTests.swift
//
// ADR 0071 push half against real git. Fixture: bare origin + a
// publisher clone (to move the remote independently) + the subscriber
// under test. `.serialized` for the same Windows-VM load rationale as
// SyncOpsRealGitTests.

import Foundation
@testable import GitCore
import Testing

// `.serialized`: multi-repo fixtures with pushes per test; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("SyncOps.pushCurrentBranch — against real git", .serialized)
struct SyncOpsPushTests {
    private struct Fixture {
        let root: URL
        let origin: URL
        let publisher: URL
        let subscriber: URL
    }

    private func makeFixture(_ label: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-pushops-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootRunner = Runner(defaultWorkingDirectory: root)

        let origin = root.appendingPathComponent("origin.git")
        _ = try await rootRunner.run(["init", "--bare", "-b", "main", origin.path])
        let publisher = root.appendingPathComponent("publisher")
        _ = try await rootRunner.run(["clone", origin.path, publisher.path])
        try await configure(publisher)
        try await commit(named: "seed.txt", at: publisher)
        _ = try await Runner(defaultWorkingDirectory: publisher).run(["push", "origin", "main"])

        let subscriber = root.appendingPathComponent("subscriber")
        _ = try await rootRunner.run(["clone", origin.path, subscriber.path])
        try await configure(subscriber)
        return Fixture(root: root, origin: origin, publisher: publisher, subscriber: subscriber)
    }

    private func configure(_ repo: URL) async throws {
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
    }

    private func commit(named name: String, at repo: URL) async throws {
        try Data("\(name)\n".utf8).write(to: repo.appendingPathComponent(name))
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["add", name])
        _ = try await runner.run(["commit", "-m", "add \(name)"])
    }

    private func originMainSHA(_ fixture: Fixture) async throws -> String {
        let out = try await Runner(defaultWorkingDirectory: fixture.origin)
            .run(["rev-parse", "refs/heads/main"])
        return out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("ahead branch pushes its commits to the upstream")
    func aheadBranchPushes() async throws {
        let fixture = try await makeFixture("ahead")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await commit(named: "local.txt", at: fixture.subscriber)

        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))
        let outcome = try await sync.pushCurrentBranch()

        #expect(outcome == .pushed(branch: "main", upstream: "origin/main", commits: 1))
        // The bare origin really advanced to the subscriber's HEAD.
        let localHEAD = try await Runner(defaultWorkingDirectory: fixture.subscriber)
            .run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try await originMainSHA(fixture) == localHEAD)
    }

    @Test("in-sync branch reports nothingToPush")
    func inSyncReportsNothing() async throws {
        let fixture = try await makeFixture("insync")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))
        let outcome = try await sync.pushCurrentBranch()

        #expect(outcome == .nothingToPush(branch: "main"))
    }

    @Test("branch without upstream is published with -u and tracks afterwards")
    func publishesNewUpstream() async throws {
        let fixture = try await makeFixture("publish")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)
        _ = try await runner.run(["switch", "-c", "feature/new"])
        try await commit(named: "feature.txt", at: fixture.subscriber)

        let sync = SyncOps(runner: runner)
        let outcome = try await sync.pushCurrentBranch()

        #expect(outcome == .publishedNewUpstream(branch: "feature/new", remote: "origin"))
        // Tracking really got configured + a second call has nothing to do.
        let states = try await sync.branchSyncStates()
        let feature = try #require(states.first { $0.name == "feature/new" })
        #expect(feature.upstreamShort == "origin/feature/new")
        #expect(try await sync.pushCurrentBranch() == .nothingToPush(branch: "feature/new"))
    }

    @Test("diverged upstream is rejected as non-fast-forward — never forced")
    func divergedIsRejected() async throws {
        let fixture = try await makeFixture("diverge")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Remote moves on…
        try await commit(named: "remote.txt", at: fixture.publisher)
        _ = try await Runner(defaultWorkingDirectory: fixture.publisher).run(["push"])
        // …while the subscriber commits locally without fetching.
        try await commit(named: "local.txt", at: fixture.subscriber)

        let beforeSHA = try await originMainSHA(fixture)
        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))
        let outcome = try await sync.pushCurrentBranch()

        #expect(outcome == .rejectedNonFastForward(branch: "main"))
        // The remote is untouched — the whole point.
        #expect(try await originMainSHA(fixture) == beforeSHA)
    }

    @Test("repo with no remotes reports noRemotes")
    func noRemotes() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-pushops-noremote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        try await configure(dir)
        try await commit(named: "seed.txt", at: dir)

        let outcome = try await SyncOps(runner: runner).pushCurrentBranch()
        #expect(outcome == .noRemotes(branch: "main"))
    }

    @Test("detached HEAD reports detachedHEAD")
    func detachedHead() async throws {
        let fixture = try await makeFixture("detached")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)
        let head = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["switch", "--detach", head])

        let outcome = try await SyncOps(runner: runner).pushCurrentBranch()
        #expect(outcome == .detachedHEAD)
    }
}
