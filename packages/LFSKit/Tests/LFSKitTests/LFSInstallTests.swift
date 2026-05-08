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
        let runner = Runner(defaultWorkingDirectory: tmp)
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

    // MARK: - Probe never throws

    @Test("probe in a fresh repo never throws and returns sensible defaults")
    func probeFreshRepoNeverThrows() async throws {
        let (root, runner) = try await mkRepo("fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = await LFSInstall.probe(runner: runner)
        // `configured` is false on a fresh repo (we haven't set
        // filter.lfs.clean anywhere); `binaryAvailable` depends on
        // the runner environment.
        #expect(!status.configured)
    }

    // MARK: - configured detection (independent of git-lfs install)

    @Test("filter.lfs.clean unset → configured == false")
    func configuredFalseWhenUnset() async throws {
        let (root, runner) = try await mkRepo("unset")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = await LFSInstall.probe(runner: runner)
        #expect(!status.configured)
    }

    @Test("filter.lfs.clean set in local config → configured == true")
    func configuredTrueWhenSetLocally() async throws {
        let (root, runner) = try await mkRepo("local")
        defer { try? FileManager.default.removeItem(at: root) }
        try await setLocalFilterClean(value: "git-lfs clean -- %f", runner: runner)
        let status = await LFSInstall.probe(runner: runner)
        #expect(status.configured)
    }

    @Test("explicitly empty filter.lfs.clean still reads as not configured")
    func emptyValueIsNotConfigured() async throws {
        let (root, runner) = try await mkRepo("empty-value")
        defer { try? FileManager.default.removeItem(at: root) }
        // `git config` requires a non-empty value to set a key, so
        // we set whitespace and verify the trim catches it.
        try await setLocalFilterClean(value: "   ", runner: runner)
        let status = await LFSInstall.probe(runner: runner)
        #expect(!status.configured)
    }

    // MARK: - binaryAvailable consistency

    @Test("binaryVersion is non-nil iff binaryAvailable is true")
    func binaryAvailableMatchesVersion() async throws {
        let (root, runner) = try await mkRepo("binary-consistency")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = await LFSInstall.probe(runner: runner)
        #expect(status.binaryAvailable == (status.binaryVersion != nil))
    }

    @Test("when binary IS available, version starts with 'git-lfs/'")
    func binaryVersionFormat() async throws {
        let (root, runner) = try await mkRepo("version-format")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = await LFSInstall.probe(runner: runner)
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
}
