import Foundation
import Testing

/// Runs the built `sprigctl` executable against temp repos and validates the
/// stdout/stderr/exit behavior end-to-end.
///
/// The binary is located via the `SPRIGCTL_BIN` env var when set (used by CI
/// for cross-configuration testing); otherwise the tests probe the standard
/// SwiftPM `.build/<config>/sprigctl` locations.
@Suite("sprigctl end-to-end")
struct SprigctlTests {
    // MARK: - Locating the built binary

    private func locateBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["SPRIGCTL_BIN"] {
            return URL(fileURLWithPath: override)
        }
        // SwiftPM puts executables in .build/<config>/<name>. Try debug then release.
        // Walk up from the test's working directory until we find Package.swift.
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0 ..< 10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        for config in ["debug", "release"] {
            let candidate = dir
                .appendingPathComponent(".build")
                .appendingPathComponent(config)
                .appendingPathComponent("sprigctl")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw SprigctlBinaryNotFound()
    }

    private struct SprigctlBinaryNotFound: Error {}

    // MARK: - Subprocess helper

    private struct Captured {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    private func run(_ args: [String], cwd: URL? = nil) async throws -> Captured {
        let binary = try locateBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.currentDirectoryURL = cwd
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        let err = try errPipe.fileHandleForReading.readToEnd() ?? Data()
        return Captured(
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func mkRepo(_ label: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-sprigctl-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func initRepo(at url: URL) async throws {
        try await spawnGit(["init", "-b", "main"], cwd: url)
        try await spawnGit(["config", "user.email", "test@sprig.app"], cwd: url)
        try await spawnGit(["config", "user.name", "Sprig Test"], cwd: url)
        try await spawnGit(["config", "commit.gpgsign", "false"], cwd: url)
    }

    private func spawnGit(_ args: [String], cwd: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = cwd
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    // MARK: - Tests

    @Test("sprigctl --help exits 0 and lists subcommands")
    func sprigctlHelpExits0AndListsSubcommands() async throws {
        let out = try await run(["--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("status"))
        #expect(out.stdout.contains("version"))
    }

    @Test("sprigctl version prints sprigctl + git versions")
    func sprigctlVersionPrintsSprigctlGitVersions() async throws {
        let out = try await run(["version"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("sprigctl"))
        #expect(out.stdout.contains("git"))
    }

    @Test("sprigctl status on a fresh repo prints clean summary")
    func sprigctlStatusOnAFreshRepoPrintsCleanSummary() async throws {
        let repo = try mkRepo("clean")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(at: repo)
        try write("hi\n", to: repo.appendingPathComponent("README.md"))
        try await spawnGit(["add", "README.md"], cwd: repo)
        try await spawnGit(["commit", "-m", "initial"], cwd: repo)

        let out = try await run(["status", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("branch: main"))
        #expect(out.stdout.contains("(clean)"))
    }

    @Test("sprigctl status reports untracked files in human output")
    func sprigctlStatusReportsUntrackedFilesInHumanOutput() async throws {
        let repo = try mkRepo("untracked")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(at: repo)
        try write("hello\n", to: repo.appendingPathComponent("hello.txt"))

        let out = try await run(["status", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("??  hello.txt"))
    }

    @Test("sprigctl status --json emits parseable JSON with entries array")
    func sprigctlStatusJsonEmitsParseableJSONWithEntriesArray() async throws {
        let repo = try mkRepo("json")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await initRepo(at: repo)
        try write("hello\n", to: repo.appendingPathComponent("hello.txt"))

        let out = try await run(["status", "--json", repo.path])
        #expect(out.exitCode == 0)
        let data = try #require(out.stdout.data(using: .utf8))
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let entries = try #require(parsed["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["kind"] as? String == "untracked")
        #expect(entries.first?["path"] as? String == "hello.txt")
    }

    @Test("sprigctl status on a non-repo path exits non-zero with a useful error")
    func sprigctlStatusOnANonRepoPathExitsNonZeroWithAUsefulError() async throws {
        let tmp = try mkRepo("notarepo")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let out = try await run(["status", tmp.path])
        #expect(out.exitCode != 0)
        // git prints "fatal: not a git repository" on stderr; our Runner
        // threads that through as GitError.nonZeroExit which ArgumentParser
        // renders to stderr.
        #expect(out.stderr.contains("not a git repository") || out.stderr.contains("fatal"))
    }
}
