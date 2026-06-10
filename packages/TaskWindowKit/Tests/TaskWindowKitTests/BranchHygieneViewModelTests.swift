// BranchHygieneViewModelTests.swift
//
// ADR 0073 view-model journeys against real git: the safe cleanup,
// the medium-tier cleanup that must leave an ADR 0033 snapshot
// behind, and the validation rails between them. Engine
// classification details are covered by GitCore's BranchHygieneTests.

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

// `.serialized`: multi-repo fixtures with pushes per test; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("BranchHygieneViewModel — cleanup with ADR 0033 pairing", .serialized)
struct BranchHygieneViewModelTests {
    private struct Fixture {
        let root: URL
        let publisher: URL
        let subscriber: URL
        let runner: Runner
    }

    private func makeFixture(_ label: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-hygienevm-\(label)-\(UUID().uuidString)")
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
        return Fixture(
            root: root,
            publisher: publisher,
            subscriber: subscriber,
            runner: Runner(defaultWorkingDirectory: subscriber)
        )
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

    /// Publish `branch` from the subscriber, then merge + delete it
    /// on the server and prune locally — the canonical 2.4 trigger.
    private func publishThenServerMerges(_ fixture: Fixture, branch: String) async throws {
        let sub = fixture.runner
        _ = try await sub.run(["switch", "-c", branch])
        try await commit(named: "\(branch.replacingOccurrences(of: "/", with: "-")).txt", at: fixture.subscriber)
        _ = try await sub.run(["push", "-u", "origin", branch])
        _ = try await sub.run(["switch", "main"])
        let pub = Runner(defaultWorkingDirectory: fixture.publisher)
        _ = try await pub.run(["fetch", "origin"])
        _ = try await pub.run(["merge", "--ff-only", "origin/\(branch)"])
        _ = try await pub.run(["push", "origin", "main"])
        _ = try await pub.run(["push", "origin", "--delete", branch])
        _ = try await SyncOps(runner: sub).fetchAll()
    }

    private func branchExists(_ name: String, _ runner: Runner) async throws -> Bool {
        let probe = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "refs/heads/\(name)"],
            throwOnNonZero: false
        )
        return probe.exitCode == 0
    }

    @Test("safe stale branch: refresh lists it, cleanUp deletes it, list shrinks")
    func safeCleanupJourney() async throws {
        let fixture = try await makeFixture("safe")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await publishThenServerMerges(fixture, branch: "feature/done")

        let vm = BranchHygieneViewModel(repoURL: fixture.subscriber, runner: fixture.runner)
        await vm.refresh()
        let stale = await vm.stale
        #expect(stale.map(\.name) == ["feature/done"])
        #expect(stale[0].safeToDelete)

        await vm.cleanUp("feature/done")

        #expect(await vm.state == .success("feature/done"))
        #expect(await vm.stale.isEmpty)
        #expect(try await !branchExists("feature/done", fixture.runner))
        // Low tier: no snapshot was taken.
        #expect(await vm.lastSafetyCopy == nil)
    }

    @Test("unsafe stale branch: cleanUp refuses; cleanUpKeepingSafetyCopy snapshots then deletes")
    func unsafeCleanupKeepsSafetyCopy() async throws {
        let fixture = try await makeFixture("unsafe")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sub = fixture.runner
        _ = try await sub.run(["switch", "-c", "feature/wip"])
        try await commit(named: "wip.txt", at: fixture.subscriber)
        _ = try await sub.run(["push", "-u", "origin", "feature/wip"])
        try await commit(named: "unpushed.txt", at: fixture.subscriber)
        let tipSHA = try await sub.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await sub.run(["switch", "main"])
        _ = try await Runner(defaultWorkingDirectory: fixture.publisher)
            .run(["push", "origin", "--delete", "feature/wip"])
        _ = try await SyncOps(runner: sub).fetchAll()

        let vm = BranchHygieneViewModel(repoURL: fixture.subscriber, runner: fixture.runner)
        await vm.refresh()
        let wip = try #require(await vm.stale.first { $0.name == "feature/wip" })
        #expect(!wip.safeToDelete)

        // The safe verb must refuse and leave the branch alone.
        await vm.cleanUp("feature/wip")
        guard case let .failure(failure) = await vm.state else {
            Issue.record("expected refusal for unsafe branch")
            return
        }
        #expect(failure.description.contains("unpushed"))
        #expect(try await branchExists("feature/wip", fixture.runner))

        // The medium-tier verb snapshots the tip, then deletes.
        await vm.cleanUpKeepingSafetyCopy("feature/wip")

        #expect(await vm.state == .success("feature/wip"))
        #expect(try await !branchExists("feature/wip", fixture.runner))
        let safetyCopy = try #require(await vm.lastSafetyCopy)
        // The snapshot ref exists on disk and points at the deleted tip.
        let resolved = try await sub.run(["rev-parse", safetyCopy.refName]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(resolved == tipSHA, "the safety copy must preserve the exact deleted tip")
    }

    @Test("unknown branch names are rejected without spawning git")
    func unknownNameRejected() async throws {
        let fixture = try await makeFixture("unknown")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let vm = BranchHygieneViewModel(repoURL: fixture.subscriber, runner: fixture.runner)
        await vm.refresh()
        await vm.cleanUp("never-heard-of-it")

        guard case let .failure(failure) = await vm.state else {
            Issue.record("expected validation failure")
            return
        }
        #expect(failure.description.contains("not in the stale-branch list"))
    }
}
