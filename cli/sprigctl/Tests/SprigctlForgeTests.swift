// SprigctlForgeTests.swift
//
// `sprigctl forge` end-to-end (ADR 0081) — the storage verbs run
// against real git + the real store helper, sharing the
// `sprigctl credential` key convention (service forge.<provider> /
// account token) so the two faces are interchangeable.
//
// `login`'s happy path is NOT exercised here — it would hit the real
// forge over the network; the device-flow polling contract is pinned
// deterministically in ForgeKit's ForgeDeviceFlowTests. The CLI
// pins: the unsupported-provider guidance and the storage verbs.
// Fixtures isolate the helper chain at the environment level
// (quirk G2 — the `credential.helper=""` reset idiom is not honored
// by git 2.54's Windows build).

import Foundation
import Testing

@Suite("sprigctl forge")
struct SprigctlForgeTests {
    private func makeRepo(_ label: String) async throws -> (repo: URL, env: [String: String]) {
        let repo = try Sprigctl.mkRepo("forge-\(label)")
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

    @Test("status with nothing stored exits 1 and says not connected")
    func statusNotConnected() async throws {
        let (repo, env) = try await makeRepo("status-empty")
        defer { try? FileManager.default.removeItem(at: repo) }

        let out = try await Sprigctl.run(
            ["forge", "status", "--provider", "github", repo.path],
            environment: env
        )
        #expect(out.exitCode == 1)
        #expect(out.stdout == "github: not connected.\n")
    }

    @Test("status sees a token stored via sprigctl credential — one key convention")
    func statusSeesCredentialSetToken() async throws {
        let (repo, env) = try await makeRepo("status-stored")
        defer { try? FileManager.default.removeItem(at: repo) }

        _ = try await Sprigctl.run(
            ["credential", "--set", "--service", "forge.github", "--account", "token", repo.path],
            stdin: Data("gho_tok\n".utf8),
            environment: env
        )
        let out = try await Sprigctl.run(
            ["forge", "status", "--provider", "github", repo.path],
            environment: env
        )
        #expect(out.exitCode == 0)
        #expect(out.stdout == "github: connected (token stored).\n")
    }

    @Test("logout forgets the token and is idempotent")
    func logoutForgets() async throws {
        let (repo, env) = try await makeRepo("logout")
        defer { try? FileManager.default.removeItem(at: repo) }

        _ = try await Sprigctl.run(
            ["credential", "--set", "--service", "forge.gitlab", "--account", "token", repo.path],
            stdin: Data("glpat-x\n".utf8),
            environment: env
        )
        let logout = try await Sprigctl.run(
            ["forge", "logout", "--provider", "gitlab", repo.path],
            environment: env
        )
        #expect(logout.exitCode == 0)
        #expect(logout.stdout == "Disconnected gitlab.\n")

        let status = try await Sprigctl.run(
            ["forge", "status", "--provider", "gitlab", repo.path],
            environment: env
        )
        #expect(status.exitCode == 1)

        let again = try await Sprigctl.run(
            ["forge", "logout", "--provider", "gitlab", repo.path],
            environment: env
        )
        #expect(again.exitCode == 0)
    }

    @Test("login on a forge without device flow names the PAT alternative")
    func loginUnsupportedProvider() async throws {
        let (repo, env) = try await makeRepo("unsupported")
        defer { try? FileManager.default.removeItem(at: repo) }

        let out = try await Sprigctl.run(
            [
                "forge", "login",
                "--provider", "bitbucket",
                "--client-id", "x",
                repo.path
            ],
            environment: env
        )
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("no device sign-in"))
        #expect(out.stderr.contains("personal access token"))
        #expect(out.stderr.contains("sprigctl credential --set --service forge.bitbucket"))
    }

    @Test("an unknown provider is an argument-parsing error, not a crash")
    func unknownProviderRejected() async throws {
        let out = try await Sprigctl.run(
            ["forge", "status", "--provider", "sourcehut"]
        )
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("provider"))
    }
}
