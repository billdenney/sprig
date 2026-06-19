// SubmoduleFreshness — "should we nudge the user about this submodule?"
// detection (ADR 0096).
//
// Tier 1 portable. Pure Foundation; spawns git via `GitCore.Runner`.
//
// Two independent signals, both surfaced per submodule:
//
//   1. OUT-OF-DATE — the submodule's checked-out HEAD differs from the
//      SHA the super-repo records in its tree. This is exactly the `+`
//      state of `git submodule status` (``SubmoduleEntry/State/outOfDate``),
//      so we read it straight off the parsed status without a second
//      spawn. It means "the super-repo says checkout X, but the
//      submodule is sitting at Y" — `submodule update` would move it.
//
//   2. UPSTREAM-NEWER — the submodule's REMOTE has commits the
//      submodule's checked-out HEAD doesn't. This is the "your pinned
//      dependency has updates available" signal and requires looking
//      at the submodule's own refs (it is invisible from the
//      super-repo's `submodule status`). We compare HEAD against the
//      submodule's upstream: `@{u}` when the submodule is on a branch,
//      else `origin/HEAD` for the canonical detached-HEAD checkout that
//      `submodule update` produces. The count of `HEAD..<upstream>`
//      commits is the "how far behind" number.
//
// This module is READ-ONLY: it never fetches and never mutates. It
// reports against whatever remote-tracking refs already exist locally
// (the ADR 0068 background auto-fetch keeps those warm). A caller that
// wants fresh upstream data fetches first, then asks.

import Foundation
import GitCore

/// One submodule's freshness signals relative to the super-repo's
/// recorded pointer and the submodule's own upstream.
public struct SubmoduleFreshness: Sendable, Equatable {
    /// The submodule's path, relative to the super-repo worktree.
    public let path: String

    /// `true` when the checked-out HEAD differs from the SHA the
    /// super-repo records (the `+` state of `git submodule status`).
    public let isOutOfDate: Bool

    /// Number of commits the submodule's upstream has that its
    /// checked-out HEAD does not (`git rev-list --count HEAD..<upstream>`).
    /// `0` when up to date with — or ahead of — the upstream; `nil`
    /// when no upstream could be resolved (uninitialized submodule, no
    /// remote-tracking ref, bare/unborn). Treated as "no upstream-newer
    /// signal" by ``shouldSuggestUpdate``.
    public let commitsBehindUpstream: Int?

    public init(path: String, isOutOfDate: Bool, commitsBehindUpstream: Int?) {
        self.path = path
        self.isOutOfDate = isOutOfDate
        self.commitsBehindUpstream = commitsBehindUpstream
    }

    /// The heuristic ADR 0096's throttled suggestion fires on: the
    /// submodule is out of date relative to the super-repo OR its
    /// upstream has commits the checkout lacks.
    public var shouldSuggestUpdate: Bool {
        isOutOfDate || (commitsBehindUpstream ?? 0) > 0
    }
}

/// Read-only freshness detection for a super-repo's submodules.
public enum SubmoduleFreshnessProbe {
    /// Probe every top-level submodule of the super-repo at `worktree`
    /// for the two freshness signals.
    ///
    /// - Parameters:
    ///   - worktree: super-repo worktree root.
    ///   - runner: ``GitCore/Runner`` for the super-repo. A per-submodule
    ///     runner is derived from it (same `gitPath`, `environmentOverrides`,
    ///     and `log`) with `cwd` pointed at each submodule.
    /// - Returns: one ``SubmoduleFreshness`` per top-level submodule, in
    ///   `git submodule status` order. Uninitialized submodules are
    ///   included (out-of-date reflects the status char; upstream is
    ///   `nil` because there's no checkout to compare).
    public static func probe(
        at worktree: URL,
        runner: Runner
    ) async throws -> [SubmoduleFreshness] {
        let standardized = worktree.standardized
        let entries = try await SubmoduleStatus.fetch(
            at: standardized,
            runner: runner,
            recursive: false
        )
        var results: [SubmoduleFreshness] = []
        results.reserveCapacity(entries.count)
        for entry in entries {
            let behind = try await commitsBehindUpstream(
                for: entry,
                superRepo: standardized,
                runner: runner
            )
            results.append(SubmoduleFreshness(
                path: entry.path,
                isOutOfDate: entry.state == .outOfDate,
                commitsBehindUpstream: behind
            ))
        }
        return results
    }

    /// Resolve `git rev-list --count HEAD..<upstream>` inside the
    /// submodule. `nil` when the submodule isn't initialized or no
    /// upstream ref resolves.
    private static func commitsBehindUpstream(
        for entry: SubmoduleEntry,
        superRepo: URL,
        runner: Runner
    ) async throws -> Int? {
        // An uninitialized submodule has no working repo to query.
        guard entry.state != .notInitialized else { return nil }

        let subRunner = Runner(
            gitPath: runner.gitPath,
            defaultWorkingDirectory: superRepo.appendingPathComponent(entry.path),
            environmentOverrides: runner.environmentOverrides,
            log: runner.log
        )
        guard let upstream = try await upstreamRef(runner: subRunner) else { return nil }

        let count = try await subRunner.run(
            ["rev-list", "--count", "HEAD..\(upstream)"],
            throwOnNonZero: false
        )
        guard count.exitCode == 0 else { return nil }
        let trimmed = count.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    /// The ref name to compare HEAD against: the configured upstream
    /// (`@{u}`) when the submodule is on a branch, else the remote's
    /// default branch (`origin/HEAD`) for the detached-HEAD checkout
    /// `git submodule update` produces. `nil` when neither resolves.
    private static func upstreamRef(runner: Runner) async throws -> String? {
        // On a branch: the configured upstream, if it resolves.
        let tracking = try await runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            throwOnNonZero: false
        )
        if tracking.exitCode == 0 {
            let name = tracking.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, try await resolvesToCommit(name, runner: runner) { return name }
        }
        // Detached HEAD (the `submodule update` default): try origin/HEAD,
        // then conventional names. Each candidate is VERIFIED to resolve —
        // a STALE origin/HEAD (remote default renamed/deleted) still prints
        // a name but no longer points at a commit, which would otherwise
        // silently swallow the upstream-newer signal.
        for candidate in try await detachedCandidates(runner: runner) {
            guard try await resolvesToCommit(candidate, runner: runner) else { continue }
            return candidate
        }
        return nil
    }

    /// Ordered upstream candidates for a detached submodule HEAD.
    private static func detachedCandidates(runner: Runner) async throws -> [String] {
        var candidates: [String] = []
        let head = try await runner.run(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            throwOnNonZero: false
        )
        if head.exitCode == 0 {
            let name = head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { candidates.append(name) }
        }
        candidates.append(contentsOf: ["origin/main", "origin/master"])
        // Last resort: a remote whose default was renamed away from
        // main/master leaves a single origin/<newname>; use it if unique.
        let branches = try await runner.run(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"],
            throwOnNonZero: false
        )
        if branches.exitCode == 0 {
            let refs = branches.stdoutString
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "origin/HEAD" }
            if refs.count == 1 { candidates.append(refs[0]) }
        }
        return candidates
    }

    /// Whether `ref` resolves to a commit object in this repo.
    private static func resolvesToCommit(_ ref: String, runner: Runner) async throws -> Bool {
        let result = try await runner.run(
            ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"],
            throwOnNonZero: false
        )
        return result.exitCode == 0
    }
}
