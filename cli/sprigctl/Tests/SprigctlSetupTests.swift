// SprigctlSetupTests.swift
//
// `sprigctl setup --global-ignore` end-to-end: the explicit-consent
// face of the §11.11 ask-less provision. The fixture pins
// core.excludesFile in LOCAL scope so the test never touches the
// machine's real global state.

import Foundation
import GitCore
import Testing

@Suite("sprigctl setup")
struct SprigctlSetupTests {
    @Test("setup without a provision flag errors helpfully")
    func requiresAFlag() async throws {
        let repo = try Sprigctl.mkRepo("setup-noflag")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)

        let out = try await Sprigctl.run(["setup", repo.path])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("--global-ignore"))
    }

    @Test("--global-ignore provisions the excludes file and silences OS noise")
    func globalIgnoreProvisions() async throws {
        let repo = try Sprigctl.mkRepo("setup-ignore")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        let excludes = repo.appendingPathComponent("test-excludes")
        try await Sprigctl.spawnGit(
            ["config", "core.excludesFile", excludes.path], cwd: repo
        )
        try Sprigctl.write("noise\n", to: repo.appendingPathComponent(".DS_Store"))

        let out = try await Sprigctl.run(["setup", "--global-ignore", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Global excludes file:"))
        #expect(out.stdout.contains(".DS_Store"))

        let status = try await Runner(defaultWorkingDirectory: repo)
            .run(["status", "--porcelain"]).stdoutString
        #expect(!status.contains(".DS_Store"), "noise ignored after provisioning")

        // Second run reports already-covered and changes nothing.
        let rerun = try await Sprigctl.run(["setup", "--global-ignore", repo.path])
        #expect(rerun.exitCode == 0)
        #expect(rerun.stdout.contains("Already covered"))
    }
}
