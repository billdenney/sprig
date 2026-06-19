// TagOpsTests.swift
//
// ADR 0087 — annotated-tag creation against real git.

import Foundation
@testable import GitCore
import Testing

@Suite("TagOps — annotated tags (real git)", .serialized)
struct TagOpsTests {
    private struct Fixture {
        let dir: URL
        let runner: Runner
        let firstSHA: String
    }

    private func makeRepo(_ label: String) async throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-tagops-\(label)-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "c1"])
        let firstSHA = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("a\nb\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["commit", "-am", "c2"])
        return Fixture(dir: dir, runner: runner, firstSHA: firstSHA)
    }

    @Test("createAnnotatedTag creates an annotated tag at the given commit")
    func createsAnnotatedTag() async throws {
        let fixture = try await makeRepo("create")
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let runner = fixture.runner
        let tags = TagOps(runner: runner)

        let outcome = try await tags.createAnnotatedTag(name: "v1.0.0", message: "Release 1.0.0", at: fixture.firstSHA)
        #expect(outcome == .created(name: "v1.0.0"))
        // It's an ANNOTATED tag (object type `tag`, not `commit`).
        let type = try await runner.run(["cat-file", "-t", "v1.0.0"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(type == "tag")
        // ...pointing at the requested commit.
        let target = try await runner.run(["rev-list", "-n", "1", "v1.0.0"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(target == fixture.firstSHA)
        #expect(try await tags.exists("v1.0.0"))
        #expect(try await tags.list().contains("v1.0.0"))
    }

    @Test("createAnnotatedTag refuses an existing tag rather than clobbering")
    func refusesExisting() async throws {
        let fixture = try await makeRepo("exists")
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let runner = fixture.runner
        let tags = TagOps(runner: runner)
        _ = try await tags.createAnnotatedTag(name: "v1.0.0", message: "first", at: fixture.firstSHA)

        let outcome = try await tags.createAnnotatedTag(name: "v1.0.0", message: "second", at: "HEAD")
        #expect(outcome == .refusedAlreadyExists(name: "v1.0.0"))
        // Still points at the original commit (not clobbered).
        let target = try await runner.run(["rev-list", "-n", "1", "v1.0.0"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(target == fixture.firstSHA)
    }

    @Test("exists is false for an unknown tag")
    func existsFalse() async throws {
        let fixture = try await makeRepo("missing")
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        #expect(try await TagOps(runner: fixture.runner).exists("nope") == false)
    }
}
