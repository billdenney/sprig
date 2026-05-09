@testable import DiagKit
import Foundation
import GitCore
import Testing

@Suite("EnvironmentCollector — runtime probes")
struct EnvironmentCollectorTests {
    @Test("collect populates engine version from the caller-supplied string")
    func enginePassesThrough() async {
        let runner = Runner()
        let report = await EnvironmentCollector.collect(
            runner: runner,
            engineVersion: "test-engine-1.2.3"
        )
        #expect(report.engine.version == "test-engine-1.2.3")
    }

    @Test("collect populates os.name with one of the known platform constants")
    func osNameKnownConstant() async {
        let runner = Runner()
        let report = await EnvironmentCollector.collect(
            runner: runner,
            engineVersion: "x"
        )
        let knownNames: Set = ["macOS", "Linux", "Windows", "Other"]
        #expect(knownNames.contains(report.os.name))
    }

    @Test("collect populates os.architecture with one of the known arch constants")
    func archKnownConstant() async {
        let runner = Runner()
        let report = await EnvironmentCollector.collect(
            runner: runner,
            engineVersion: "x"
        )
        let knownArchs: Set = ["arm64", "x86_64", "i386", "arm", "Other"]
        #expect(knownArchs.contains(report.os.architecture))
    }

    @Test("collect populates os.versionString from ProcessInfo")
    func osVersionStringNonEmpty() async {
        let runner = Runner()
        let report = await EnvironmentCollector.collect(
            runner: runner,
            engineVersion: "x"
        )
        // ProcessInfo always returns a non-empty string on supported
        // platforms — assert that floor here. The exact shape varies
        // and we don't pin it.
        #expect(!report.os.versionString.isEmpty)
    }

    @Test("collect probes real git and parses the version when available")
    func gitProbeWithRealRunner() async throws {
        let runner = Runner()
        let report = await EnvironmentCollector.collect(
            runner: runner,
            engineVersion: "x"
        )
        // CI runners (and developer machines) all have git on PATH.
        // If they didn't, GitCore's whole test suite wouldn't run —
        // so we can rely on this for an integration assertion.
        let gitRaw = try #require(report.git.gitVersionRaw)
        #expect(gitRaw.hasPrefix("git version "))
        let parsed = try #require(report.git.gitVersion)
        // Sprig's floor is 2.39 (ADR 0047) and CI pins ≥ 2.39, so
        // assert the floor without pinning to a specific upstream.
        #expect(parsed.major >= 2)
    }

    @Test("collect uses the supplied clock for generatedAt")
    func clockIsRespected() async {
        let runner = Runner()
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let report = await EnvironmentCollector.collect(
            runner: runner,
            engineVersion: "x",
            clock: { fixed }
        )
        #expect(report.generatedAt == fixed)
    }

    @Test("collect returns a report even when the runner can't find git")
    func collectGracefulOnMissingGit() async {
        // Point the runner at a path that definitely isn't git.
        // `Runner` resolves git via PATH; setting `gitPath` to a
        // bogus absolute path forces resolveGitPath to use it.
        var runner = Runner()
        runner.gitPath = "/this/path/does/not/exist/git"

        let report = await EnvironmentCollector.collect(
            runner: runner,
            engineVersion: "x"
        )
        // git probe should fail gracefully; the rest of the report
        // remains populated.
        #expect(report.git.gitVersionRaw == nil)
        #expect(report.git.gitVersion == nil)
        #expect(report.git.gitLFSVersionRaw == nil)
        #expect(report.engine.version == "x")
        #expect(!report.os.versionString.isEmpty)
    }
}
