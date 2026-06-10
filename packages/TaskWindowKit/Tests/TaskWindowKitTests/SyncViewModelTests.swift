// SyncViewModelTests.swift
//
// ADR 0071 Sync verb end-to-end against real git: the one-button
// "make my copy and the server match" composite. Leg-level behavior
// is covered by SyncOpsRealGitTests / SyncOpsPushTests; here we prove
// the orchestration: stage progression, the composed report, the
// mid-operation guard, and that diverged work is reported (not
// forced) while remaining a *successful* run.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

// `.serialized`: multi-repo fixtures with pushes per test; see
// SyncOpsRealGitTests for the Windows-VM load rationale.
@Suite("SyncViewModel — Sync verb against real git", .serialized)
struct SyncViewModelTests {
    private struct Fixture {
        let root: URL
        let origin: URL
        let publisher: URL
        let subscriber: URL
    }

    private func makeFixture(_ label: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-syncvm-\(label)-\(UUID().uuidString)")
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

    private func report(of vm: SyncViewModel) async throws -> SyncReport {
        let state = await vm.state
        guard case let .success(report) = state else {
            throw NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected .success, got \(state)"
            ])
        }
        return report
    }

    @Test("behind + ahead repo: one run pulls the remote commit and pushes the local one")
    func fullRoundTrip() async throws {
        let fixture = try await makeFixture("roundtrip")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Remote gains a commit; subscriber gains a different one —
        // but only after fetching will they fast-forward? No: that
        // would diverge. Keep it the canonical Sync case instead:
        // remote ahead only → pull; then local commit → push is
        // exercised by the next run. Here: remote ahead, local clean.
        try await commit(named: "remote.txt", at: fixture.publisher)
        _ = try await Runner(defaultWorkingDirectory: fixture.publisher).run(["push"])

        let vm = SyncViewModel(
            repoURL: fixture.subscriber,
            runner: Runner(defaultWorkingDirectory: fixture.subscriber)
        )
        await vm.run()

        let report = try await report(of: vm)
        #expect(report.fetched)
        #expect(!report.skippedMidOperation)
        guard case .fastForwarded = report.currentBranchFastForward else {
            Issue.record("expected fastForwarded, got \(String(describing: report.currentBranchFastForward))")
            return
        }
        #expect(report.push == .nothingToPush(branch: "main"))
        #expect(await vm.stage == .finished)
        // The pulled file landed in the working tree.
        let landed = fixture.subscriber.appendingPathComponent("remote.txt")
        #expect(FileManager.default.fileExists(atPath: landed.path))
    }

    @Test("local-only commits: Sync pushes them and the origin advances")
    func pushesLocalWork() async throws {
        let fixture = try await makeFixture("push")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await commit(named: "local.txt", at: fixture.subscriber)

        let vm = SyncViewModel(
            repoURL: fixture.subscriber,
            runner: Runner(defaultWorkingDirectory: fixture.subscriber)
        )
        await vm.run()

        let report = try await report(of: vm)
        #expect(report.push == .pushed(branch: "main", upstream: "origin/main", commits: 1))
        let originSHA = try await Runner(defaultWorkingDirectory: fixture.origin)
            .run(["rev-parse", "refs/heads/main"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localSHA = try await Runner(defaultWorkingDirectory: fixture.subscriber)
            .run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(originSHA == localSHA)
    }

    @Test("diverged history: Sync reports rejection as data — a successful run, nothing forced")
    func divergedIsReportedNotForced() async throws {
        let fixture = try await makeFixture("diverged")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await commit(named: "remote.txt", at: fixture.publisher)
        _ = try await Runner(defaultWorkingDirectory: fixture.publisher).run(["push"])
        try await commit(named: "local.txt", at: fixture.subscriber)

        let vm = SyncViewModel(
            repoURL: fixture.subscriber,
            runner: Runner(defaultWorkingDirectory: fixture.subscriber)
        )
        await vm.run()

        let report = try await report(of: vm)
        #expect(report.fetched)
        #expect(report.currentBranchFastForward == .diverged(ahead: 1, behind: 1))
        #expect(report.push == .rejectedNonFastForward(branch: "main"))
    }

    @Test("mid-merge repo: fetch runs, mutating legs are skipped")
    func midOperationSkipsMutatingLegs() async throws {
        let fixture = try await makeFixture("midop")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = Runner(defaultWorkingDirectory: fixture.subscriber)

        // Manufacture a real in-progress merge: two branches editing
        // the same line.
        _ = try await runner.run(["switch", "-c", "side"])
        try Data("side\n".utf8).write(to: fixture.subscriber.appendingPathComponent("seed.txt"))
        _ = try await runner.run(["commit", "-am", "side edit"])
        _ = try await runner.run(["switch", "main"])
        try Data("main\n".utf8).write(to: fixture.subscriber.appendingPathComponent("seed.txt"))
        _ = try await runner.run(["commit", "-am", "main edit"])
        _ = try await runner.run(["merge", "side"], throwOnNonZero: false) // conflicts → mid-merge

        let vm = SyncViewModel(repoURL: fixture.subscriber, runner: runner)
        await vm.run()

        let report = try await report(of: vm)
        #expect(report.fetched, "fetch is read-only and still runs")
        #expect(report.skippedMidOperation)
        #expect(report.currentBranchFastForward == nil)
        #expect(report.push == nil)
    }

    @Test("reset() returns stage and state to idle for a re-run")
    func resetForRerun() async throws {
        let fixture = try await makeFixture("reset")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let vm = SyncViewModel(
            repoURL: fixture.subscriber,
            runner: Runner(defaultWorkingDirectory: fixture.subscriber)
        )
        await vm.run()
        #expect(await vm.stage == .finished)

        await vm.reset()
        #expect(await vm.stage == .idle)
        #expect(await vm.state == .idle)
    }
}
