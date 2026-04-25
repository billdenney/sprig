import Foundation
@testable import GitCore
import Testing

@Suite("LogParser — against real git")
struct LogIntegrationTests {
    private func mkRepo(_ label: String) throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-log-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (tmp, Runner(defaultWorkingDirectory: tmp))
    }

    private func initRepo(_ runner: Runner) async throws {
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
    }

    @Test("log of a fresh single-commit repo parses one commit with the expected fields")
    func singleCommitRepo() async throws {
        let (repo, runner) = try mkRepo("single")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        try Data("hi\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        _ = try await runner.run(["add", "README.md"])
        _ = try await runner.run(["commit", "-m", "first commit"])

        let output = try await runner.run([
            "log", "-z", "--format=\(LogParser.formatString)"
        ])
        let commits = try LogParser.parse(output.stdout)
        #expect(commits.count == 1)
        let c = commits[0]
        #expect(c.subject == "first commit")
        #expect(c.author.email == "test@sprig.app")
        #expect(c.author.name == "Sprig Test")
        #expect(c.parents.isEmpty)
        #expect(!c.isMerge)
    }

    @Test("multiple commits return in reverse-chronological order (git default)")
    func multipleCommitsOrdered() async throws {
        let (repo, runner) = try mkRepo("multi")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)

        for i in 0 ..< 3 {
            try Data("v\(i)\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
            _ = try await runner.run(["add", "a.txt"])
            _ = try await runner.run(["commit", "-m", "commit \(i)"])
        }

        let output = try await runner.run([
            "log", "-z", "--format=\(LogParser.formatString)"
        ])
        let commits = try LogParser.parse(output.stdout)
        #expect(commits.count == 3)
        // git log defaults to reverse-chronological (newest first).
        #expect(commits.map(\.subject) == ["commit 2", "commit 1", "commit 0"])
    }

    @Test("merge commit reports two parents")
    func mergeCommit() async throws {
        let (repo, runner) = try mkRepo("merge")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)

        try Data("base\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "base"])

        _ = try await runner.run(["checkout", "-b", "feature"])
        try Data("feature side\n".utf8).write(to: repo.appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "b.txt"])
        _ = try await runner.run(["commit", "-m", "feature work"])

        _ = try await runner.run(["checkout", "main"])
        try Data("main side\n".utf8).write(to: repo.appendingPathComponent("c.txt"))
        _ = try await runner.run(["add", "c.txt"])
        _ = try await runner.run(["commit", "-m", "main work"])

        _ = try await runner.run([
            "merge", "--no-ff", "feature", "-m", "merge feature"
        ])

        let output = try await runner.run([
            "log", "-z", "--format=\(LogParser.formatString)"
        ])
        let commits = try LogParser.parse(output.stdout)
        let merges = commits.filter(\.isMerge)
        #expect(merges.count == 1)
        #expect(merges.first?.subject == "merge feature")
        #expect(merges.first?.parents.count == 2)
    }

    @Test("commit with multi-line body preserves the body")
    func multiLineBody() async throws {
        let (repo, runner) = try mkRepo("body")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        try Data("x\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run([
            "commit", "-m", "subject line",
            "-m", "body paragraph one",
            "-m", "body paragraph two"
        ])

        let output = try await runner.run([
            "log", "-z", "--format=\(LogParser.formatString)"
        ])
        let commits = try LogParser.parse(output.stdout)
        let c = commits[0]
        #expect(c.subject == "subject line")
        #expect(c.body.contains("subject line"))
        #expect(c.body.contains("body paragraph one"))
        #expect(c.body.contains("body paragraph two"))
    }

    @Test("--max-count maps to git's -n flag and bounds commit count")
    func maxCountBounds() async throws {
        let (repo, runner) = try mkRepo("max")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(runner)
        for i in 0 ..< 5 {
            try Data("\(i)\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
            _ = try await runner.run(["add", "a.txt"])
            _ = try await runner.run(["commit", "-m", "c\(i)"])
        }

        let output = try await runner.run([
            "log", "-n", "2", "-z", "--format=\(LogParser.formatString)"
        ])
        let commits = try LogParser.parse(output.stdout)
        #expect(commits.count == 2)
    }
}
