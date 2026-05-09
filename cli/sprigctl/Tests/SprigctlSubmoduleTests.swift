import Foundation
import Testing

// `sprigctl submodule` end-to-end CLI tests. Lives in its own file so
// neither it nor `SprigctlTests.swift` trips SwiftLint's `file_length`
// or `type_body_length` caps as the surface grows.

@Suite("sprigctl submodule")
struct SprigctlSubmoduleTests {
    // MARK: - Mode-flag plumbing

    @Test("submodule --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["submodule", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.lowercased().contains("submodule"))
        #expect(out.stdout.contains("--status"))
    }

    @Test("submodule without --status errors with a helpful message")
    func errorsWithoutMode() async throws {
        let out = try await Sprigctl.run(["submodule"])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("--status"))
    }

    // MARK: - --status

    @Test("submodule --status on a repo with no submodules prints `no submodules`")
    func statusEmpty() async throws {
        let repo = try Sprigctl.mkRepo("submodule-empty")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try Sprigctl.write("seed\n", to: repo.appendingPathComponent("seed.txt"))
        try await Sprigctl.spawnGit(["add", "seed.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)

        let out = try await Sprigctl.run(["submodule", "--status", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("no submodules"))
    }

    @Test("submodule --status lists a single submodule with state and path")
    func statusSingleSubmodule() async throws {
        let (parent, helper) = try await Self.mkRepoWithSubmodule(label: "submodule-status-single")
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: helper)
        }

        let out = try await Sprigctl.run(["submodule", "--status", parent.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("1 submodule"))
        #expect(out.stdout.contains("clean"))
        #expect(out.stdout.contains("sub"))
    }

    @Test("submodule --status --recursive flattens nested submodules")
    func statusRecursive() async throws {
        let nested = try await Self.mkRepoWithNestedSubmodule(
            label: "submodule-status-recursive"
        )
        defer {
            try? FileManager.default.removeItem(at: nested.parent)
            try? FileManager.default.removeItem(at: nested.helper)
            try? FileManager.default.removeItem(at: nested.nestedHelper)
        }

        let out = try await Sprigctl.run(
            ["submodule", "--status", "--recursive", nested.parent.path]
        )
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("2 submodules"))
        #expect(out.stdout.contains("sub"))
        #expect(out.stdout.contains("sub/deeper"))
    }

    @Test("submodule --status --json emits parseable JSON with the entries array")
    func statusJSON() async throws {
        let (parent, helper) = try await Self.mkRepoWithSubmodule(label: "submodule-status-json")
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: helper)
        }

        let out = try await Sprigctl.run(
            ["submodule", "--status", "--json", parent.path]
        )
        #expect(out.exitCode == 0)
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(parsed as? [String: Any])
        let entries = try #require(dict["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry["state"] as? String == "clean")
        #expect(entry["path"] as? String == "sub")
        let sha = try #require(entry["recordedSHA"] as? String)
        #expect(sha.count == 40 || sha.count == 64)
    }

    // MARK: - Fixture builders

    /// Build a parent repo with a single-level submodule pointing at
    /// a helper repo. Uses `Sprigctl.spawnGit` rather than GitCore's
    /// `Runner` so this stays a pure CLI integration test (matches
    /// the pattern in the `--status` LFS tests, where Sprigctl's
    /// helpers do all repo bring-up).
    private static func mkRepoWithSubmodule(
        label: String
    ) async throws -> (parent: URL, helper: URL) {
        let helper = try Sprigctl.mkRepo("\(label)-helper")
        try await Sprigctl.initRepo(at: helper)
        try Sprigctl.write("seed\n", to: helper.appendingPathComponent("h.txt"))
        try await Sprigctl.spawnGit(["add", "h.txt"], cwd: helper)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: helper)

        let parent = try Sprigctl.mkRepo("\(label)-parent")
        try await Sprigctl.initRepo(at: parent)
        try Sprigctl.write("p\n", to: parent.appendingPathComponent("p.txt"))
        try await Sprigctl.spawnGit(["add", "p.txt"], cwd: parent)
        try await Sprigctl.spawnGit(["commit", "-m", "p"], cwd: parent)

        try await Sprigctl.spawnGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", helper.path, "sub"],
            cwd: parent
        )
        try await Sprigctl.spawnGit(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"],
            cwd: parent
        )
        try await Sprigctl.spawnGit(["commit", "-m", "add sub"], cwd: parent)

        return (parent, helper)
    }

    /// Result of ``mkRepoWithNestedSubmodule(label:)`` — the URLs of
    /// the temporary repos so callers can clean them up. A struct
    /// rather than a 3-tuple to satisfy SwiftLint's `large_tuple` rule.
    private struct NestedFixture {
        var parent: URL
        var helper: URL
        var nestedHelper: URL
    }

    private static func mkRepoWithNestedSubmodule(
        label: String
    ) async throws -> NestedFixture {
        let nestedHelper = try Sprigctl.mkRepo("\(label)-nested")
        try await Sprigctl.initRepo(at: nestedHelper)
        try Sprigctl.write("nested\n", to: nestedHelper.appendingPathComponent("n.txt"))
        try await Sprigctl.spawnGit(["add", "n.txt"], cwd: nestedHelper)
        try await Sprigctl.spawnGit(["commit", "-m", "nested"], cwd: nestedHelper)

        let helper = try Sprigctl.mkRepo("\(label)-helper")
        try await Sprigctl.initRepo(at: helper)
        try Sprigctl.write("seed\n", to: helper.appendingPathComponent("h.txt"))
        try await Sprigctl.spawnGit(["add", "h.txt"], cwd: helper)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: helper)
        try await Sprigctl.spawnGit(
            [
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "add",
                nestedHelper.path,
                "deeper"
            ],
            cwd: helper
        )
        try await Sprigctl.spawnGit(["commit", "-m", "add deeper"], cwd: helper)

        let parent = try Sprigctl.mkRepo("\(label)-parent")
        try await Sprigctl.initRepo(at: parent)
        try Sprigctl.write("p\n", to: parent.appendingPathComponent("p.txt"))
        try await Sprigctl.spawnGit(["add", "p.txt"], cwd: parent)
        try await Sprigctl.spawnGit(["commit", "-m", "p"], cwd: parent)

        try await Sprigctl.spawnGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", helper.path, "sub"],
            cwd: parent
        )
        try await Sprigctl.spawnGit(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"],
            cwd: parent
        )
        try await Sprigctl.spawnGit(["commit", "-m", "add sub"], cwd: parent)

        return NestedFixture(parent: parent, helper: helper, nestedHelper: nestedHelper)
    }
}
