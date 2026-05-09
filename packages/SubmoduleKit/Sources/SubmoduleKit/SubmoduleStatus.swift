// SubmoduleStatus — async wrapper around `git submodule status`.
//
// Tier 1 portable. Pure Foundation; spawns git via `GitCore.Runner`.
//
// Read-only surface this slice. Mutating operations (`init`,
// `update`, `deinit`, `sync`, `add`) are deferred — they need
// SafetyKit snapshot hooks per CLAUDE.md rule 8 and live in a later
// slice.

import Foundation
import GitCore

/// Async wrappers for submodule status read operations.
public enum SubmoduleStatus {
    /// Which SHA git should report for each submodule.
    public enum Source: Sendable, Equatable {
        /// Default. SHA reflects the submodule's working-tree HEAD
        /// (what `git submodule status` reports without `--cached`).
        /// When the submodule is initialized and on a describable
        /// ref, the entry's `refDescription` is populated.
        case workingTree
        /// `--cached`. SHA reflects what the super-repo records in
        /// its tree, regardless of the submodule's checkout state.
        /// Entries never carry a `refDescription` in this mode.
        case recorded
    }

    /// Run `git submodule status` in `worktree` and return the parsed
    /// entries.
    ///
    /// - Parameters:
    ///   - worktree: super-repo's worktree root.
    ///   - runner: ``GitCore/Runner`` to spawn git with. Required —
    ///     no default — so callers explicitly thread the
    ///     `RunnerLog` (per ADR 0057) and `cwd`/lock-contention
    ///     awareness through. A default-constructed `Runner()` here
    ///     would silently drop log entries from the agent's
    ///     command-history view.
    ///   - recursive: passes `--recursive` to git, flattening nested
    ///     submodules into a single result list. Default false.
    ///   - source: ``Source/workingTree`` for checkout-state SHAs
    ///     (default), or ``Source/recorded`` to pass `--cached` and
    ///     get the super-repo's recorded SHAs. Default
    ///     ``Source/workingTree``.
    public static func fetch(
        at worktree: URL,
        runner: Runner,
        recursive: Bool = false,
        source: Source = .workingTree
    ) async throws -> [SubmoduleEntry] {
        let standardized = worktree.standardized
        var arguments: [String] = ["submodule", "status"]
        if recursive {
            arguments.append("--recursive")
        }
        if source == .recorded {
            arguments.append("--cached")
        }

        let output = try await runner.run(arguments, cwd: standardized)

        // Strict UTF-8 decode. `String(bytes:encoding:)` returns nil
        // (rather than substituting U+FFFD) when bytes aren't valid
        // UTF-8, so a failure here surfaces malformed git output
        // rather than silently dropping submodules.
        guard let stdoutText = String(bytes: output.stdout, encoding: .utf8) else {
            throw GitError.parseFailure(
                context: "git submodule status emitted non-UTF-8 bytes",
                rawSnippet: ""
            )
        }
        return try SubmoduleStatusParser.parse(stdoutText)
    }

    /// Convenience: list every submodule's worktree URL under
    /// `worktree`. Equivalent to ``fetch(at:runner:recursive:source:)``
    /// composed with `entries.map { worktree.appendingPathComponent($0.path).standardized }`.
    ///
    /// Defaults to `recursive: true` because the original use case —
    /// a watcher enumerating every gitDir to subscribe to — wants
    /// every level of nesting. Callers that need just the top-level
    /// listing can pass `recursive: false` (or call ``fetch`` directly
    /// and map themselves).
    ///
    /// State is intentionally elided here: a callsite that wanted
    /// "watcher targets" doesn't care whether the submodule is
    /// out-of-date, only that it exists at all. Callers who do care
    /// about state should use ``fetch`` and inspect each entry.
    public static func worktreeURLs(
        at worktree: URL,
        runner: Runner,
        recursive: Bool = true
    ) async throws -> [URL] {
        let standardized = worktree.standardized
        let entries = try await fetch(
            at: standardized,
            runner: runner,
            recursive: recursive
        )
        return entries.map { entry in
            standardized.appendingPathComponent(entry.path).standardized
        }
    }
}
