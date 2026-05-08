// LFSInstall.swift
//
// Detects whether `git-lfs` is installed and whether `git lfs install`
// has been run (i.e. `filter.lfs.*` config keys are set, globally or
// for the current repo).
//
// Powers the ADR 0029 one-click installer flow: at clone time, or the
// first time the user opens a repo with LFS-tracked content, Sprig
// surfaces a "git-lfs isn't set up; install it now?" prompt iff this
// probe says LFS isn't ready.
//
// Tier 1; depends only on GitCore for `Runner`.

import Foundation
import GitCore

/// Snapshot of `git-lfs` install state at one moment for one repo.
public struct LFSInstallStatus: Equatable, Hashable, Sendable {
    /// True iff the `git-lfs` binary is on PATH and `git lfs version`
    /// returns a non-empty string with exit code 0. False if git-lfs
    /// isn't installed (`git: 'lfs' is not a git command`) or the
    /// version output is empty.
    public let binaryAvailable: Bool

    /// `git lfs version`'s stdout (single line) when
    /// ``binaryAvailable`` is true; nil otherwise. Includes the
    /// leading product name (e.g. `git-lfs/3.4.0 (GitHub; …)`) so
    /// callers that want to gate on a minimum version can substring-
    /// match without reformatting.
    public let binaryVersion: String?

    /// True iff `filter.lfs.clean` is set to a non-empty value
    /// somewhere git can see — global config, system config, or
    /// local-repo config. The clean filter is the canonical signal
    /// that `git lfs install` has been run; the `smudge` / `process`
    /// keys are set together with it, so checking one is sufficient.
    public let configured: Bool

    /// All three required pieces in place: binary on PATH AND
    /// configured. The convenience for the common gate at the merge
    /// / clone surface ("can we transparently smudge LFS pointers?").
    public var isReady: Bool {
        binaryAvailable && configured
    }

    public init(binaryAvailable: Bool, binaryVersion: String?, configured: Bool) {
        self.binaryAvailable = binaryAvailable
        self.binaryVersion = binaryVersion
        self.configured = configured
    }
}

/// Errors `LFSInstall.probe` surfaces when the environment is
/// fundamentally broken — distinct from the expected "git-lfs isn't
/// installed" / "filter not configured" states which are reported
/// non-throwing as fields on ``LFSInstallStatus``.
public enum LFSProbeError: Error, Sendable, CustomStringConvertible {
    /// `git` itself isn't usable — couldn't spawn at all (binary
    /// missing from PATH, exec permission denied, signal trap, I/O
    /// failure on the working directory, etc). Distinct from
    /// "git-lfs isn't installed" because the entire Sprig engine
    /// can't function without git, so callers should surface this
    /// as a fatal setup error rather than the LFS-specific install
    /// prompt.
    ///
    /// `step` describes which probe step failed (`"git lfs version"`
    /// or `"git config --get filter.lfs.clean"`) so the diagnostic
    /// surfaces which subprocess invocation was unable to run.
    case gitNotAvailable(step: String, underlying: Error)

    public var description: String {
        switch self {
        case let .gitNotAvailable(step, underlying):
            "LFS install probe could not invoke git at step `\(step)`. " +
                "Sprig requires git to be installed and on PATH for any " +
                "LFS operation. Underlying: \(underlying)"
        }
    }
}

/// Stateless `git-lfs` install probe. Pass a `Runner` configured for
/// the repo whose status you want; the probe runs `git lfs version`
/// (binary check) and `git config --get filter.lfs.clean` (config
/// check) and returns the combined status.
public enum LFSInstall {
    /// Probe `git-lfs` install state.
    ///
    /// **Returns** an ``LFSInstallStatus`` describing the EXPECTED
    /// states the caller cares about for the install-prompt flow:
    /// git-lfs binary present-or-absent, filter.lfs.clean
    /// configured-or-not. "git-lfs isn't installed" is a normal
    /// state to detect — not an error.
    ///
    /// **Throws** ``LFSProbeError/gitNotAvailable(step:underlying:)``
    /// if the underlying git invocation can't even run (binary
    /// missing, launch failure, signal). Distinct from "git-lfs
    /// isn't installed" so callers can disambiguate "user needs to
    /// install git-lfs" from "user's git itself is broken; this is
    /// a Sprig-level environment problem."
    public static func probe(runner: Runner) async throws -> LFSInstallStatus {
        let binaryVersion = try await probeBinary(runner: runner)
        let configured = try await probeConfigured(runner: runner)
        return LFSInstallStatus(
            binaryAvailable: binaryVersion != nil,
            binaryVersion: binaryVersion,
            configured: configured
        )
    }

    /// Run `git lfs version`. Returns the version string when the
    /// subprocess exits 0 with non-empty output. Returns nil when
    /// the subprocess runs but reports git-lfs is missing (non-zero
    /// exit, or zero exit with empty output). Throws
    /// ``LFSProbeError/gitNotAvailable`` if git itself can't run.
    private static func probeBinary(runner: Runner) async throws -> String? {
        let result: Runner.Output
        do {
            result = try await runner.run(
                ["lfs", "version"],
                throwOnNonZero: false
            )
        } catch {
            // With `throwOnNonZero: false`, the only thing that can
            // throw is launch failure. Surface as gitNotAvailable.
            throw LFSProbeError.gitNotAvailable(
                step: "git lfs version",
                underlying: error
            )
        }
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Run `git config --get filter.lfs.clean`. Returns true iff
    /// the subprocess exits 0 with non-empty trimmed output. Throws
    /// ``LFSProbeError/gitNotAvailable`` if git itself can't run.
    private static func probeConfigured(runner: Runner) async throws -> Bool {
        let result: Runner.Output
        do {
            result = try await runner.run(
                ["config", "--get", "filter.lfs.clean"],
                throwOnNonZero: false
            )
        } catch {
            throw LFSProbeError.gitNotAvailable(
                step: "git config --get filter.lfs.clean",
                underlying: error
            )
        }
        guard result.exitCode == 0 else { return false }
        let trimmed = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }
}
