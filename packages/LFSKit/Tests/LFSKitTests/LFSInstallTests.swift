import Foundation
import GitCore
@testable import LFSKit
import Testing

@Suite("LFSInstall — git-lfs binary + config probe")
struct LFSInstallTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-lfs-install-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Isolate the test's git invocations from the runner host's
        // global / system git config. macOS and Windows hosted CI
        // runners ship with git-lfs installed (Homebrew on macOS,
        // Chocolatey on Windows), and `brew install git-lfs` runs
        // `git lfs install --system` which sets `filter.lfs.*`
        // system-wide. Without this isolation, a fresh repo's
        // `git config --get filter.lfs.clean` returns the inherited
        // system value and the "no local config → not configured"
        // tests below fail spuriously.
        //
        // `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` are git's
        // documented escape hatches (git-config(1)). Pointing them at
        // a non-existent file makes git treat global / system
        // configuration as empty for the lifetime of this Runner.
        let nullConfigPath = tmp.appendingPathComponent(".no-config").path
        let runner = Runner(
            defaultWorkingDirectory: tmp,
            environmentOverrides: [
                "GIT_CONFIG_GLOBAL": nullConfigPath,
                "GIT_CONFIG_SYSTEM": nullConfigPath
            ]
        )
        _ = try await runner.run(["init", "-b", "main"])
        return (tmp, runner)
    }

    /// Set `filter.lfs.clean` in this repo's local config. Mirrors
    /// the effect of `git lfs install --local` without requiring the
    /// git-lfs binary to be present, so the configured-detection
    /// tests work even on CI runners that don't have git-lfs.
    private func setLocalFilterClean(value: String, runner: Runner) async throws {
        _ = try await runner.run(["config", "--local", "filter.lfs.clean", value])
    }

    // MARK: - Happy-path defaults

    @Test("probe in a fresh repo returns sensible defaults — does not throw")
    func probeFreshRepoReturnsDefaults() async throws {
        let (root, runner) = try await mkRepo("fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = try await LFSInstall.probe(runner: runner)
        // `configured` is false on a fresh repo (we haven't set
        // filter.lfs.clean anywhere; the test Runner is isolated
        // from inherited config). `binaryAvailable` depends on the
        // runner environment — git-lfs is installed on hosted
        // macOS / Windows runners, absent in the Linux container.
        #expect(!status.configured)
    }

    // MARK: - configured detection (independent of git-lfs install)

    @Test("filter.lfs.clean unset → configured == false")
    func configuredFalseWhenUnset() async throws {
        let (root, runner) = try await mkRepo("unset")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = try await LFSInstall.probe(runner: runner)
        #expect(!status.configured)
    }

    @Test("filter.lfs.clean set in local config → configured == true")
    func configuredTrueWhenSetLocally() async throws {
        let (root, runner) = try await mkRepo("local")
        defer { try? FileManager.default.removeItem(at: root) }
        try await setLocalFilterClean(value: "git-lfs clean -- %f", runner: runner)
        let status = try await LFSInstall.probe(runner: runner)
        #expect(status.configured)
    }

    @Test("explicitly empty filter.lfs.clean still reads as not configured")
    func emptyValueIsNotConfigured() async throws {
        let (root, runner) = try await mkRepo("empty-value")
        defer { try? FileManager.default.removeItem(at: root) }
        // `git config` requires a non-empty value to set a key, so
        // we set whitespace and verify the trim catches it.
        try await setLocalFilterClean(value: "   ", runner: runner)
        let status = try await LFSInstall.probe(runner: runner)
        #expect(!status.configured)
    }

    // MARK: - binaryAvailable consistency

    @Test("binaryVersion is non-nil iff binaryAvailable is true")
    func binaryAvailableMatchesVersion() async throws {
        let (root, runner) = try await mkRepo("binary-consistency")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = try await LFSInstall.probe(runner: runner)
        #expect(status.binaryAvailable == (status.binaryVersion != nil))
    }

    @Test("when binary IS available, version starts with 'git-lfs/'")
    func binaryVersionFormat() async throws {
        let (root, runner) = try await mkRepo("version-format")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = try await LFSInstall.probe(runner: runner)
        // Conditional assertion: only check format if the runner
        // environment has git-lfs installed. Otherwise we'd be
        // testing the test runner's environment, not our code.
        if let version = status.binaryVersion {
            #expect(version.hasPrefix("git-lfs/"), "unexpected version string: \(version)")
        }
    }

    // MARK: - isReady gate

    @Test("isReady requires both binaryAvailable AND configured")
    func isReadyGate() {
        // Build candidate states by hand to verify the boolean logic.
        let neither = LFSInstallStatus(binaryAvailable: false, binaryVersion: nil, configured: false)
        let onlyBinary = LFSInstallStatus(binaryAvailable: true, binaryVersion: "git-lfs/3.0.0", configured: false)
        let onlyConfig = LFSInstallStatus(binaryAvailable: false, binaryVersion: nil, configured: true)
        let both = LFSInstallStatus(binaryAvailable: true, binaryVersion: "git-lfs/3.0.0", configured: true)
        #expect(!neither.isReady)
        #expect(!onlyBinary.isReady)
        #expect(!onlyConfig.isReady)
        #expect(both.isReady)
    }

    // MARK: - Error path: git itself isn't usable

    @Test("probe throws gitNotAvailable when git binary cannot be launched")
    func probeThrowsWhenGitMissing() async throws {
        // Construct a Runner whose `gitPath` points at a path that
        // doesn't exist. Runner's `resolveGitPath()` returns this
        // verbatim when it's set (line 276); the spawn then fails
        // with a launch error, which the probe surfaces as
        // `LFSProbeError.gitNotAvailable` rather than silently
        // reporting "git-lfs not installed."
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-no-git-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runner = Runner(
            gitPath: tmp.appendingPathComponent("nonexistent-git-binary").path,
            defaultWorkingDirectory: tmp
        )
        await #expect(throws: LFSProbeError.self) {
            _ = try await LFSInstall.probe(runner: runner)
        }
    }

    @Test("gitNotAvailable description names the failing step + underlying error")
    func errorDescriptionMentionsStep() {
        struct DummyError: Error, CustomStringConvertible {
            var description: String {
                "boom"
            }
        }
        let error = LFSProbeError.gitNotAvailable(
            step: "git lfs version",
            underlying: DummyError()
        )
        let text = String(describing: error)
        #expect(text.contains("git lfs version"))
        #expect(text.contains("boom"))
        #expect(text.contains("git to be installed"))
    }
}
