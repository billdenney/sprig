// SyncViewModelPushRailsTests.swift
//
// ADR 0093 push-time rails surfaced through the Sync verb. Split from
// SyncViewModelTests to keep each suite under the type-body-length cap.
// Real git, bare-origin fixtures (same shape as SyncViewModelTests).

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("SyncViewModel — push-time rails (ADR 0093, real git)", .serialized)
struct SyncViewModelPushRailsTests {
    private struct Fixture {
        let root: URL
        let origin: URL
        let publisher: URL
        let subscriber: URL
    }

    private func makeFixture(_ label: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-syncvm-pushrails-\(label)-\(UUID().uuidString)")
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

    @Test("push rails surface in the report: protected branch + force consequence + secret in outgoing")
    func pushRailsSurfaceInReport() async throws {
        let fixture = try await makeFixture("rails")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Origin advances (subscriber will be behind)…
        try await commit(named: "remote.txt", at: fixture.publisher)
        _ = try await Runner(defaultWorkingDirectory: fixture.publisher).run(["push"])
        // …and the subscriber commits a SECRET locally (ahead + diverged).
        // Fragment-built so no contiguous token literal lands in source.
        let secret = "AKIA" + "IOSFODNN7EXAMPLE"
        try Data("AWS_KEY = \"\(secret)\"\n".utf8)
            .write(to: fixture.subscriber.appendingPathComponent("config.env"))
        let sub = Runner(defaultWorkingDirectory: fixture.subscriber)
        _ = try await sub.run(["add", "config.env"])
        _ = try await sub.run(["commit", "-m", "add config"])

        let vm = SyncViewModel(repoURL: fixture.subscriber, runner: sub)
        await vm.run()
        let report = try await report(of: vm)

        let ids = Set(report.preflightWarnings.map(\.railID))
        #expect(ids.contains("pushing-to-protected-branch"))
        #expect(ids.contains("force-push-consequence"))
        #expect(ids.contains("secret-in-outgoing-commits"))
        // Unchanged Sync semantics: the diverged push is reported, never forced.
        #expect(report.push == .rejectedNonFastForward(branch: "main"))
    }

    @Test("suppressed push rails do not surface")
    func suppressedPushRailsSilent() async throws {
        let fixture = try await makeFixture("suppress")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await commit(named: "local.txt", at: fixture.subscriber) // ahead only, on main + upstream

        let sub = Runner(defaultWorkingDirectory: fixture.subscriber)
        let suppressed = PreflightChecks(suppressedRails: [
            "pushing-to-protected-branch", "force-push-consequence", "secret-in-outgoing-commits"
        ])
        let vm = SyncViewModel(repoURL: fixture.subscriber, runner: sub, preflight: suppressed)
        await vm.run()
        let report = try await report(of: vm)
        #expect(report.preflightWarnings.isEmpty)
    }
}
