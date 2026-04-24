import Foundation
@testable import GitCore
import Testing

/// Tests that actually spawn the system `git` binary.
///
/// Per the project testing strategy (§5.5 of the plan), we prefer real git over
/// mocks. These tests are fast enough to run in the unit suite; larger fixture
/// work lives in `tests/integration/`.
@Suite("Runner end-to-end (spawns real git)")
struct RunnerTests {
    @Test
    func `version() returns a parseable GitVersion meeting our minimum`() async throws {
        let runner = Runner()
        let version = try await runner.version()
        #expect(version.major >= 2)
        #expect(
            version.meetsMinimum,
            "System git \(version) is below Sprig's minimum (\(GitVersion.minimumSupported))."
        )
    }

    @Test
    func `run() captures stdout and stderr separately`() async throws {
        let runner = Runner()
        let output = try await runner.run(["--version"])
        #expect(output.exitCode == 0)
        #expect(output.stdoutString.hasPrefix("git version"))
        #expect(output.stderrString.isEmpty)
    }

    @Test
    func `run() throws nonZeroExit for an unknown subcommand`() async throws {
        let runner = Runner()
        do {
            _ = try await runner.run(["this-is-not-a-git-subcommand-xyzzy"])
            Issue.record("expected GitError.nonZeroExit")
        } catch let GitError.nonZeroExit(_, code, stderr, _) {
            #expect(code != 0)
            #expect(!stderr.isEmpty)
        }
    }

    @Test
    func `throwOnNonZero=false returns the non-zero output instead of throwing`() async throws {
        let runner = Runner()
        let output = try await runner.run(
            ["this-is-not-a-git-subcommand-xyzzy"],
            throwOnNonZero: false
        )
        #expect(output.exitCode != 0)
    }

    @Test
    func `init/status round-trip in a temporary repo`() async throws {
        let tmp = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])

        let status = try await runner.run(["status", "--porcelain=v2"])
        #expect(status.exitCode == 0)
        // Empty repo with no untracked files → porcelain output should be empty.
        #expect(status.stdoutString.isEmpty)
    }

    @Test
    func `scrubbed environment forces deterministic UTF-8 locale and disables prompts`() {
        let runner = Runner()
        let scrubbed = runner.scrubbedEnvironment(base: [
            "GIT_DIR": "/should/be/removed",
            "GIT_WORK_TREE": "/should/be/removed",
            "LC_ALL": "de_DE.UTF-8",
            "SOME_OTHER_VAR": "preserved"
        ])
        #expect(scrubbed["GIT_DIR"] == nil)
        #expect(scrubbed["GIT_WORK_TREE"] == nil)
        #expect(scrubbed["LC_ALL"] == "C.UTF-8")
        #expect(scrubbed["LANG"] == "C.UTF-8")
        #expect(scrubbed["GIT_TERMINAL_PROMPT"] == "0")
        #expect(scrubbed["SOME_OTHER_VAR"] == "preserved") // unrelated vars preserved
    }

    @Test
    func `environmentOverrides can re-set scrubbed vars`() {
        let runner = Runner(environmentOverrides: ["LC_ALL": "en_US.UTF-8"])
        let scrubbed = runner.scrubbedEnvironment(base: [:])
        #expect(scrubbed["LC_ALL"] == "en_US.UTF-8")
    }

    // MARK: helpers

    private func createTempDirectory() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-gitcore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}
