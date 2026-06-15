// SprigctlCredentialTests.swift
//
// `sprigctl credential` end-to-end against real git and the real
// `git-credential-store` helper (ADR 0080). Pins: the stdin secret
// path (never argv), the get/exit-code contract for scripting, and
// the remove round-trip. Fixtures isolate the helper chain at the
// ENVIRONMENT level (`Sprigctl.credentialIsolationEnvironment`) so
// machine-wide helpers (Git Credential Manager on Windows hosts)
// can't intercept — the `credential.helper=""` reset idiom is not
// honored by git 2.54's Windows build (quirk G2).

import Foundation
import Testing

@Suite("sprigctl credential")
struct SprigctlCredentialTests {
    /// Repo whose EFFECTIVE config pins the chain to one store-helper
    /// writing `creds.txt` inside the repo; `env` makes every spawned
    /// sprigctl's git blind to system/global helpers.
    private func makeRepo(_ label: String) async throws -> (repo: URL, env: [String: String]) {
        let repo = try Sprigctl.mkRepo("credential-\(label)")
        try await Sprigctl.initRepo(at: repo)
        let home = repo.appendingPathComponent("fixture-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let storePath = repo.appendingPathComponent("creds.txt").path
            .replacingOccurrences(of: "\\", with: "/")
        try await Sprigctl.spawnGit(
            ["config", "credential.helper", "store --file=\(storePath)"],
            cwd: repo
        )
        return (repo, Sprigctl.credentialIsolationEnvironment(home: home))
    }

    @Test("set reads the secret from stdin; get prints it back")
    func setThenGet() async throws {
        let (repo, env) = try await makeRepo("roundtrip")
        defer { try? FileManager.default.removeItem(at: repo) }

        let set = try await Sprigctl.run(
            ["credential", "--set", "--service", "forge.github", "--account", "token", repo.path],
            stdin: Data("tok-12345\n".utf8),
            environment: env
        )
        #expect(set.exitCode == 0)
        #expect(set.stdout.isEmpty, "set must never echo the secret")

        let get = try await Sprigctl.run(
            ["credential", "--get", "--service", "forge.github", "--account", "token", repo.path],
            environment: env
        )
        #expect(get.exitCode == 0)
        #expect(get.stdout == "tok-12345\n")
    }

    @Test("get with nothing stored exits 1 with a stderr explanation, empty stdout")
    func getMissing() async throws {
        let (repo, env) = try await makeRepo("missing")
        defer { try? FileManager.default.removeItem(at: repo) }

        let get = try await Sprigctl.run(
            ["credential", "--get", "--service", "forge.github", "--account", "token", repo.path],
            environment: env
        )
        #expect(get.exitCode == 1)
        #expect(get.stdout.isEmpty)
        #expect(get.stderr.contains("no secret stored for forge.github/token"))
    }

    @Test("remove forgets the secret; the verbs are mutually exclusive")
    func removeAndExclusivity() async throws {
        let (repo, env) = try await makeRepo("remove")
        defer { try? FileManager.default.removeItem(at: repo) }

        _ = try await Sprigctl.run(
            ["credential", "--set", "--service", "forge.gitlab", "--account", "token", repo.path],
            stdin: Data("glpat-x\n".utf8),
            environment: env
        )
        let removed = try await Sprigctl.run(
            ["credential", "--remove", "--service", "forge.gitlab", "--account", "token", repo.path],
            environment: env
        )
        #expect(removed.exitCode == 0)

        let get = try await Sprigctl.run(
            ["credential", "--get", "--service", "forge.gitlab", "--account", "token", repo.path],
            environment: env
        )
        #expect(get.exitCode == 1)

        let both = try await Sprigctl.run(
            ["credential", "--set", "--get", "--service", "x", "--account", "y", repo.path],
            stdin: Data(),
            environment: env
        )
        #expect(both.exitCode != 0)
        #expect(both.stderr.contains("exactly one of"))
    }

    @Test("set with empty stdin is a validation error, not a stored empty secret")
    func setEmptyStdin() async throws {
        let (repo, env) = try await makeRepo("empty")
        defer { try? FileManager.default.removeItem(at: repo) }

        let set = try await Sprigctl.run(
            ["credential", "--set", "--service", "forge.github", "--account", "token", repo.path],
            stdin: Data(),
            environment: env
        )
        #expect(set.exitCode != 0)
        #expect(set.stderr.contains("no secret on stdin"))
        #expect(!FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("creds.txt").path
        ))
    }
}
