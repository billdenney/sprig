// EnvironmentCollector.swift
//
// Tier 1 portable. Spawns git via `GitCore.Runner` to discover
// `git --version` and `git lfs version`; everything else is
// Foundation + compile-time constants.
//
// Non-throwing surface: `collect(...)` always returns a report,
// even when git itself isn't usable. The `gitVersionRaw` field is
// nil in that case — a deliberately graceful degradation, since a
// support flow that says "you don't even have git" is still more
// useful than a thrown error.

import Foundation
import GitCore

/// Builds an ``EnvironmentReport`` by probing the runtime
/// environment.
public enum EnvironmentCollector {
    /// Collect a report.
    ///
    /// - Parameters:
    ///   - runner: ``GitCore/Runner`` used to invoke `git --version`
    ///     and `git lfs version`. Caller-owned so any `RunnerLog`
    ///     (per ADR 0057) and lock-contention awareness are threaded
    ///     through. No default — explicit injection only.
    ///   - engineVersion: caller-supplied engine version string
    ///     (e.g., `sprigctl --version`'s output, or the macOS app's
    ///     `CFBundleShortVersionString`). DiagKit doesn't try to
    ///     discover this — it doesn't know which embedder it lives
    ///     inside.
    ///   - clock: timestamp source for ``EnvironmentReport/generatedAt``.
    ///     Defaults to `Date.init`. Tests inject a fixed clock to
    ///     get deterministic output.
    public static func collect(
        runner: Runner,
        engineVersion: String,
        clock: () -> Date = Date.init
    ) async -> EnvironmentReport {
        async let gitProbe = probeGit(runner: runner)
        async let lfsProbe = probeGitLFS(runner: runner)
        let (gitRaw, gitParsed) = await gitProbe
        let lfsRaw = await lfsProbe

        return EnvironmentReport(
            engine: EnvironmentReport.Engine(version: engineVersion),
            os: EnvironmentReport.OperatingSystem(
                name: osName,
                versionString: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architecture
            ),
            git: EnvironmentReport.GitTooling(
                gitVersionRaw: gitRaw,
                gitVersion: gitParsed.map(EnvironmentReport.GitSemver.init),
                gitLFSVersionRaw: lfsRaw
            ),
            generatedAt: clock()
        )
    }

    // MARK: - Probes

    private static func probeGit(
        runner: Runner
    ) async -> (raw: String?, parsed: GitVersion?) {
        do {
            let output = try await runner.run(["--version"])
            guard output.exitCode == 0 else { return (nil, nil) }
            let raw = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return (nil, nil) }
            return (raw, GitVersion.parse(raw))
        } catch {
            return (nil, nil)
        }
    }

    private static func probeGitLFS(runner: Runner) async -> String? {
        do {
            // `git lfs version` is git-side-invoked even when git-lfs
            // isn't installed (the LFS wrapper command); when missing
            // git emits stderr like `git: 'lfs' is not a git command`
            // and exits non-zero. We treat any non-zero exit as
            // "absent" rather than failing the whole report.
            let output = try await runner.run(
                ["lfs", "version"],
                throwOnNonZero: false
            )
            guard output.exitCode == 0 else { return nil }
            let raw = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        } catch {
            return nil
        }
    }

    // MARK: - Compile-time constants

    //
    // Per CLAUDE.md hard rule 2, `#if os(...)` and `#if arch(...)`
    // for "trivial cross-platform constants" (PATH separator,
    // executable name, OS name string) are the explicitly
    // permitted exception. These are pure constants, no behavior
    // branching.

    private static var osName: String {
        #if os(macOS)
            "macOS"
        #elseif os(Linux)
            "Linux"
        #elseif os(Windows)
            "Windows"
        #else
            "Other"
        #endif
    }

    private static var architecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #elseif arch(i386)
            "i386"
        #elseif arch(arm)
            "arm"
        #else
            "Other"
        #endif
    }
}
