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
    /// isn't installed, isn't accessible, or the binary is broken.
    public let binaryAvailable: Bool

    /// `git lfs version`'s stdout (single line) when
    /// ``binaryAvailable`` is true; nil otherwise. Includes the
    /// leading product name (e.g. `git-lfs/3.4.0 (GitHub; …)`) so
    /// callers that want to gate on a minimum version can substring-
    /// match without reformatting.
    public let binaryVersion: String?

    /// True iff `filter.lfs.clean` is set somewhere git can see —
    /// global config, system config, or local-repo config. The clean
    /// filter is the canonical signal that `git lfs install` has
    /// been run; the `smudge` / `process` keys are set together with
    /// it, so checking one is sufficient.
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

/// Stateless `git-lfs` install probe. Pass a `Runner` configured for
/// the repo whose status you want; the probe runs `git lfs version`
/// (binary check) and `git config --get filter.lfs.clean` (config
/// check) and returns the combined status.
public enum LFSInstall {
    /// Probe `git-lfs` install state. Never throws — failures of
    /// either subprocess (non-zero exit, missing binary) are
    /// represented in the returned struct as
    /// `binaryAvailable=false` / `configured=false`. Throwing would
    /// be the wrong signal: "git-lfs not installed" is a normal
    /// state to detect, not an error.
    public static func probe(runner: Runner) async -> LFSInstallStatus {
        async let versionResult = lfsVersion(runner: runner)
        async let configuredResult = configuredFilter(runner: runner)
        let (version, configured) = await (versionResult, configuredResult)
        return LFSInstallStatus(
            binaryAvailable: version != nil,
            binaryVersion: version,
            configured: configured
        )
    }

    /// `git lfs version` → version string (full first line), or nil
    /// if git-lfs isn't installed / `git lfs` subcommand fails.
    private static func lfsVersion(runner: Runner) async -> String? {
        guard let result = try? await runner.run(
            ["lfs", "version"],
            throwOnNonZero: false
        ) else { return nil }
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `git config --get filter.lfs.clean` → true iff the value is
    /// set (exit 0). git's `--get` returns 1 with empty stdout when
    /// the key isn't set; that's our "not configured" signal.
    private static func configuredFilter(runner: Runner) async -> Bool {
        guard let result = try? await runner.run(
            ["config", "--get", "filter.lfs.clean"],
            throwOnNonZero: false
        ) else { return false }
        guard result.exitCode == 0 else { return false }
        // Defensive: an explicitly empty value is technically valid
        // but treat it as not-configured since LFS would be broken.
        let trimmed = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }
}
