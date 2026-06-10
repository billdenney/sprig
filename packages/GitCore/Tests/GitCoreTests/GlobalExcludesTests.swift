// GlobalExcludesTests.swift
//
// §11.11 / ADR 0049 amendment against real git. The load-bearing
// claims: resolution honors `core.excludesFile` (any scope, tilde
// expanded) and falls back to git's documented XDG default; the
// provision is append-only, header-once, dedup-on-rerun; and the
// real-git proof — OS droppings stop showing as untracked the moment
// the file is provisioned, with git config untouched throughout.

import Foundation
@testable import GitCore
import Testing

@Suite("GlobalExcludes — resolve + provision (real git)")
struct GlobalExcludesTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-globalexcl-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        return (dir, runner)
    }

    @Test("configured core.excludesFile wins; ~ expands against HOME")
    func configuredFileWins() async throws {
        let (dir, runner) = try await makeRepo("configured")
        defer { try? FileManager.default.removeItem(at: dir) }
        // LOCAL scope keeps the test hermetic — `config --get` reads
        // all scopes exactly like git's own excludes resolution.
        _ = try await runner.run(["config", "core.excludesFile", "~/my-ignores"])

        let resolved = try await GlobalExcludes.resolveExcludesFile(
            runner: runner,
            environment: ["HOME": "/fake/home"]
        )
        #expect(resolved.path == "/fake/home/my-ignores")
    }

    @Test("unset core.excludesFile falls back to XDG, then ~/.config/git/ignore")
    func xdgFallback() async throws {
        let (dir, runner) = try await makeRepo("xdg")
        defer { try? FileManager.default.removeItem(at: dir) }

        let xdg = try await GlobalExcludes.resolveExcludesFile(
            runner: runner,
            environment: ["XDG_CONFIG_HOME": "/fake/xdg", "HOME": "/fake/home"]
        )
        #expect(xdg.path == "/fake/xdg/git/ignore")

        let home = try await GlobalExcludes.resolveExcludesFile(
            runner: runner,
            environment: ["HOME": "/fake/home"]
        )
        #expect(home.path == "/fake/home/.config/git/ignore")
    }

    @Test("provisioned OS noise stops showing as untracked — and git config is untouched")
    func provisionMakesNoiseInvisible() async throws {
        let (dir, runner) = try await makeRepo("proof")
        defer { try? FileManager.default.removeItem(at: dir) }
        let excludes = dir.appendingPathComponent("excludes-home")
            .appendingPathComponent("ignore")
        _ = try await runner.run(["config", "core.excludesFile", excludes.path])

        try Data("noise\n".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        try Data("noise\n".utf8).write(to: dir.appendingPathComponent("Desktop.ini"))
        try Data("real\n".utf8).write(to: dir.appendingPathComponent("work.txt"))
        let before = try await runner.run(["status", "--porcelain"]).stdoutString
        #expect(before.contains(".DS_Store"), "noise visible before provisioning")

        let configBefore = try await runner.run(["config", "--list", "--local"]).stdoutString
        let result = try await GlobalExcludes.provision(runner: runner)
        let configAfter = try await runner.run(["config", "--list", "--local"]).stdoutString

        #expect(result.file == excludes)
        #expect(result.added.count == JunkFilePatterns.osNoise.count)
        #expect(configAfter == configBefore, "provisioning never writes config")
        let after = try await runner.run(["status", "--porcelain"]).stdoutString
        #expect(!after.contains(".DS_Store"))
        #expect(!after.contains("Desktop.ini"))
        #expect(after.contains("work.txt"), "real work still visible")
    }

    @Test("re-provisioning is a no-op: dedup, header once, content stable")
    func reprovisionIsNoop() async throws {
        let (dir, runner) = try await makeRepo("rerun")
        defer { try? FileManager.default.removeItem(at: dir) }
        let excludes = dir.appendingPathComponent("ignore-file")
        _ = try await runner.run(["config", "core.excludesFile", excludes.path])
        // Pre-existing user content must survive untouched.
        try Data("# theirs\n*.log\n".utf8).write(to: excludes)

        let first = try await GlobalExcludes.provision(runner: runner)
        #expect(!first.added.isEmpty)
        let contentAfterFirst = try String(contentsOf: excludes, encoding: .utf8)
        #expect(contentAfterFirst.hasPrefix("# theirs\n*.log\n"), "append-only")

        let second = try await GlobalExcludes.provision(runner: runner)
        #expect(second.added.isEmpty, "everything already covered")
        let contentAfterSecond = try String(contentsOf: excludes, encoding: .utf8)
        #expect(contentAfterSecond == contentAfterFirst, "no-op rerun leaves bytes unchanged")
        let headerCount = contentAfterSecond
            .split(whereSeparator: \.isNewline)
            .count(where: { $0 == Substring(GlobalExcludes.header) })
        #expect(headerCount == 1)
    }
}
