import Foundation
@testable import GitCore
import Testing

/// End-to-end: spawn real `git` with a `RunnerLog` attached and
/// verify the log captures the invocation accurately.
@Suite("Runner + RunnerLog — integration with real git")
struct RunnerLogIntegrationTests {
    private func mkRepo(_ test: String) async throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-runnerlog-\(test)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let r = Runner(defaultWorkingDirectory: tmp)
        _ = try await r.run(["init", "-b", "main"])
        _ = try await r.run(["config", "user.email", "test@sprig.app"])
        _ = try await r.run(["config", "user.name", "Sprig Test"])
        _ = try await r.run(["config", "commit.gpgsign", "false"])
        return tmp
    }

    @Test("a successful run records argv, exit 0, non-nil duration, and the resolved git path")
    func successfulRunRecorded() async throws {
        let log = RunnerLog()
        let root = try await mkRepo("success")
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = Runner(defaultWorkingDirectory: root, log: log)
        let before = await log.count()
        let output = try await runner.run(["status", "--porcelain=v2", "-z"])
        #expect(output.exitCode == 0)

        let entries = await log.entries()
        #expect(entries.count == before + 1)
        let entry = try #require(entries.last)
        // First argv element is the resolved git path; subsequent are
        // the arguments we supplied.
        #expect(entry.argv.first?.contains("git") == true)
        #expect(Array(entry.argv.dropFirst()) == ["status", "--porcelain=v2", "-z"])
        #expect(entry.exitCode == 0)
        #expect(entry.cwd == root.path)
        #expect(entry.duration >= 0)
        #expect(entry.duration < 5)
        #expect(entry.failed == false)
    }

    @Test("a non-zero-exit run is also recorded; exitCode reflects failure")
    func failedRunRecorded() async throws {
        let log = RunnerLog()
        // Use a non-repo path so `git status` fails with exit 128.
        let nonRepo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-runnerlog-nonrepo-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepo) }

        let runner = Runner(defaultWorkingDirectory: nonRepo, log: log)
        // Expect the call to throw; the log should still capture.
        do {
            _ = try await runner.run(["status"])
            Issue.record("expected GitError.nonZeroExit")
        } catch {
            // OK — proceed to verify the log.
        }

        let entries = await log.entries()
        let entry = try #require(entries.last)
        #expect(entry.argv.contains("status"))
        #expect(entry.exitCode != 0)
        #expect(entry.failed == true)
        // git status against a non-repo emits "fatal: not a git repository..."
        #expect(entry.stderrTail?.contains("not a git repository") == true)
    }

    @Test("nil log preserves backward-compat: run() works, no records produced")
    func nilLogIsBackwardCompat() async throws {
        let root = try await mkRepo("nil-log")
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = Runner(defaultWorkingDirectory: root) // no log
        let output = try await runner.run(["status", "--porcelain=v2", "-z"])
        #expect(output.exitCode == 0)
        // Nothing to assert about a log we don't have — the test is
        // that the call succeeds and doesn't crash.
    }

    @Test("multiple runners share one log; entries from both runners appear")
    func sharedLogAcrossRunners() async throws {
        let log = RunnerLog()
        let rootA = try await mkRepo("shared-a")
        let rootB = try await mkRepo("shared-b")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let runnerA = Runner(defaultWorkingDirectory: rootA, log: log)
        let runnerB = Runner(defaultWorkingDirectory: rootB, log: log)

        _ = try await runnerA.run(["status", "--porcelain=v2", "-z"])
        _ = try await runnerB.run(["status", "--porcelain=v2", "-z"])

        let entries = await log.entries()
        let cwds = Set(entries.compactMap(\.cwd))
        #expect(cwds.contains(rootA.path))
        #expect(cwds.contains(rootB.path))
    }

    @Test("live subscribers see commands as they complete")
    func liveSubscribersSeeCommandsLive() async throws {
        let log = RunnerLog()
        let root = try await mkRepo("live")
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = Runner(defaultWorkingDirectory: root, log: log)
        let stream = await log.events()
        try await Task.sleep(nanoseconds: 10_000_000) // 10 ms — let stream attach

        let runTask = Task {
            _ = try await runner.run(["status", "--porcelain=v2", "-z"])
        }
        try await runTask.value

        var received: [LoggedCommand] = []
        for await entry in stream {
            received.append(entry)
            if received.count == 1 { break }
        }
        #expect(received.first?.argv.contains("status") == true)
    }
}
