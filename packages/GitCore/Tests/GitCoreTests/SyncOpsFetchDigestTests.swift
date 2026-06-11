// SyncOpsFetchDigestTests.swift
//
// ADR 0077's "what changed?" digest against real git: a fetch that
// moves origin/main produces the right commit + distinct-author
// counts; a fetch that moves nothing produces no digests; brand-new
// remote branches are skipped (nothing to compare against).

import Foundation
@testable import GitCore
import Testing

// `.serialized`: multi-repo fixtures with pushes per test.
@Suite("SyncOps.fetchAllDigesting — against real git", .serialized)
struct SyncOpsFetchDigestTests {
    private struct Fixture {
        let root: URL
        let publisher: URL
        let subscriber: URL
    }

    private func makeFixture(_ label: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-digest-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootRunner = Runner(defaultWorkingDirectory: root)
        let origin = root.appendingPathComponent("origin.git")
        _ = try await rootRunner.run(["init", "--bare", "-b", "main", origin.path])
        let publisher = root.appendingPathComponent("publisher")
        _ = try await rootRunner.run(["clone", origin.path, publisher.path])
        try await configure(publisher)
        try await commit(named: "seed.txt", at: publisher, author: "Alice")
        _ = try await Runner(defaultWorkingDirectory: publisher).run(["push", "origin", "main"])
        let subscriber = root.appendingPathComponent("subscriber")
        _ = try await rootRunner.run(["clone", origin.path, subscriber.path])
        try await configure(subscriber)
        return Fixture(root: root, publisher: publisher, subscriber: subscriber)
    }

    private func configure(_ repo: URL) async throws {
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
    }

    private func commit(named name: String, at repo: URL, author: String) async throws {
        try Data("\(name)\n".utf8).write(to: repo.appendingPathComponent(name))
        let runner = Runner(defaultWorkingDirectory: repo)
        _ = try await runner.run(["add", name])
        _ = try await runner.run([
            "-c", "user.name=\(author)",
            "-c", "user.email=\(author.lowercased())@sprig.app",
            "commit", "-m", "add \(name)"
        ])
    }

    @Test("a moved ref digests with commit count and DISTINCT author count")
    func movedRefDigests() async throws {
        let fixture = try await makeFixture("moves")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Three commits, two distinct authors (Bob, Bob, Carol).
        try await commit(named: "one.txt", at: fixture.publisher, author: "Bob")
        try await commit(named: "two.txt", at: fixture.publisher, author: "Bob")
        try await commit(named: "three.txt", at: fixture.publisher, author: "Carol")
        _ = try await Runner(defaultWorkingDirectory: fixture.publisher).run(["push"])

        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))
        let digests = try await sync.fetchAllDigesting()

        #expect(digests.count == 1)
        let digest = try #require(digests.first)
        #expect(digest.ref == "origin/main")
        #expect(digest.commitCount == 3)
        #expect(digest.authorCount == 2, "Bob counted once")
        #expect(digest.oldSHA != digest.newSHA)
    }

    @Test("an unmoved remote produces no digests; a brand-new branch is skipped")
    func noMovementNoDigest() async throws {
        let fixture = try await makeFixture("still")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sync = SyncOps(runner: Runner(defaultWorkingDirectory: fixture.subscriber))

        #expect(try await sync.fetchAllDigesting().isEmpty, "nothing moved")

        // A brand-new remote branch has no old tip to digest against.
        let publisherRunner = Runner(defaultWorkingDirectory: fixture.publisher)
        _ = try await publisherRunner.run(["switch", "-c", "feature/new"])
        try await commit(named: "feat.txt", at: fixture.publisher, author: "Dora")
        _ = try await publisherRunner.run(["push", "-u", "origin", "feature/new"])

        #expect(try await sync.fetchAllDigesting().isEmpty, "new branches are skipped")
    }
}
