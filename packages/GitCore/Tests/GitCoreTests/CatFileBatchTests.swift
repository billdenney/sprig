import Foundation
@testable import GitCore
import Testing

/// End-to-end tests against real `git cat-file --batch`. Each test
/// builds a small repo in `NSTemporaryDirectory()`, makes a known
/// commit, queries through CatFileBatch, and asserts on the bytes.
@Suite("CatFileBatch — against real git")
struct CatFileBatchTests {
    // MARK: - fixtures

    private func mkRepo(_ label: String) throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-catfile-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (tmp, Runner(defaultWorkingDirectory: tmp))
    }

    private func initRepo(_ runner: Runner) async throws {
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
    }

    private func commit(
        files: [(name: String, body: String)],
        message: String,
        in runner: Runner,
        repo: URL
    ) async throws {
        for (name, body) in files {
            try Data(body.utf8).write(to: repo.appendingPathComponent(name))
            _ = try await runner.run(["add", name])
        }
        _ = try await runner.run(["commit", "-m", message])
    }

    private func revParse(_ ref: String, in runner: Runner) async throws -> String {
        let output = try await runner.run(["rev-parse", ref])
        return output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - tests

    @Test("read of a blob returns matching content + sha + kind=blob")
    func readsBlob() async throws {
        let (repo, runner) = try mkRepo("blob")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        try await commit(
            files: [("hello.txt", "Hello, Sprig!\n")],
            message: "initial",
            in: runner,
            repo: repo
        )

        // Resolve the blob SHA via `rev-parse`.
        let blobSHA = try await revParse("HEAD:hello.txt", in: runner)
        let cat = try await CatFileBatch(repoURL: repo)
        defer { Task { await cat.close() } }

        let object = try await cat.read(blobSHA)
        #expect(object.kind == .blob)
        #expect(object.sha == blobSHA)
        #expect(object.contentString == "Hello, Sprig!\n")
    }

    @Test("read of a commit returns the commit text")
    func readsCommit() async throws {
        let (repo, runner) = try mkRepo("commit")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        try await commit(
            files: [("a.txt", "a\n")],
            message: "first",
            in: runner,
            repo: repo
        )
        let commitSHA = try await revParse("HEAD", in: runner)

        let cat = try await CatFileBatch(repoURL: repo)
        defer { Task { await cat.close() } }

        let object = try await cat.read(commitSHA)
        #expect(object.kind == .commit)
        let text = try #require(object.contentString)
        #expect(text.contains("tree "))
        #expect(text.contains("first"))
        #expect(text.contains("test@sprig.app"))
    }

    @Test("read of a tree lists the files committed")
    func readsTree() async throws {
        let (repo, runner) = try mkRepo("tree")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        try await commit(
            files: [("alpha.txt", "a\n"), ("beta.txt", "b\n")],
            message: "two files",
            in: runner,
            repo: repo
        )
        let treeSHA = try await revParse("HEAD^{tree}", in: runner)

        let cat = try await CatFileBatch(repoURL: repo)
        defer { Task { await cat.close() } }

        let object = try await cat.read(treeSHA)
        #expect(object.kind == .tree)
        // Tree content is binary, but the filenames appear as raw UTF-8
        // segments inside the entries, so we can scan for them.
        let bytes = [UInt8](object.content)
        let blob = Data(bytes)
        #expect(blob.range(of: Data("alpha.txt".utf8)) != nil)
        #expect(blob.range(of: Data("beta.txt".utf8)) != nil)
    }

    @Test("multiple sequential reads share one process")
    func sequentialReads() async throws {
        let (repo, runner) = try mkRepo("sequential")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        try await commit(
            files: [
                ("one.txt", "1\n"),
                ("two.txt", "2\n"),
                ("three.txt", "3\n")
            ],
            message: "multi",
            in: runner,
            repo: repo
        )

        let cat = try await CatFileBatch(repoURL: repo)
        defer { Task { await cat.close() } }

        let expected: [(String, String)] = [
            ("one.txt", "1\n"),
            ("two.txt", "2\n"),
            ("three.txt", "3\n")
        ]
        for (name, body) in expected {
            let blobSHA = try await revParse("HEAD:\(name)", in: runner)
            let object = try await cat.read(blobSHA)
            #expect(object.kind == .blob)
            #expect(object.sha == blobSHA)
            #expect(object.contentString == body)
        }
    }

    @Test("read of a missing object throws GitError.objectNotFound")
    func missingObjectThrows() async throws {
        let (repo, runner) = try mkRepo("missing")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        try await commit(
            files: [("seed.txt", "seed\n")],
            message: "seed",
            in: runner,
            repo: repo
        )

        let cat = try await CatFileBatch(repoURL: repo)
        defer { Task { await cat.close() } }

        let madeUpSHA = String(repeating: "0", count: 40)
        do {
            _ = try await cat.read(madeUpSHA)
            Issue.record("expected GitError.objectNotFound")
        } catch let GitError.objectNotFound(name) {
            #expect(name == madeUpSHA)
        }
    }

    @Test("read after close throws GitError.closed")
    func readAfterCloseThrows() async throws {
        let (repo, runner) = try mkRepo("closed")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        try await commit(
            files: [("file.txt", "x\n")],
            message: "x",
            in: runner,
            repo: repo
        )

        let cat = try await CatFileBatch(repoURL: repo)
        await cat.close()
        do {
            _ = try await cat.read("HEAD")
            Issue.record("expected GitError.closed")
        } catch let GitError.closed(name) {
            #expect(name == "CatFileBatch")
        }
    }

    @Test("close is idempotent")
    func closeIsIdempotent() async throws {
        let (repo, runner) = try mkRepo("close-twice")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        try await commit(
            files: [("f.txt", "y\n")],
            message: "y",
            in: runner,
            repo: repo
        )

        let cat = try await CatFileBatch(repoURL: repo)
        await cat.close()
        await cat.close() // second call is a no-op, must not crash
    }
}
