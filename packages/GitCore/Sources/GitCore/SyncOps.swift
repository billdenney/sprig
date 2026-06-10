// SyncOps.swift
//
// ADR 0068 engine surface: background-sync primitives.
//
// - ``fetchAll(prune:)`` — `git fetch --all --prune`, the hourly
//   default auto-fetch (badges + behind-counts stay roughly current).
// - ``branchSyncStates()`` — parse `git for-each-ref` upstream/track
//   state for every local branch.
// - ``fastForwardLocalBranches(options:)`` — the opt-in auto-pull:
//   fast-forward every branch that can be moved *provably without
//   loss*, update the working directory for the checked-out branch,
//   and report a typed per-branch outcome for everything skipped.
//
// Fail-closed by construction: the only mutations this type performs
// are fast-forwards (git refuses non-FF on both paths used here).
// Diverged branches, dirty worktrees, missing upstreams, and branches
// checked out in other worktrees are *reported*, never resolved.
//
// Callers that run this unattended (AgentKit's AutoSyncScheduler, the
// `sprigctl sync` command) should gate the fast-forward pass on
// `GitMetadataPaths.gitOperationInFlight(in:)` per ADR 0056 — a
// mid-merge/-rebase repo skips the whole pass. The gate lives at the
// caller so interactive callers can decide to surface the reason.

import Foundation

/// Background-sync git operations for one repository. Stateless —
/// every call shells out via the wrapped ``Runner`` (which carries
/// the repo's working directory).
public struct SyncOps: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    // MARK: - Fetch

    /// `git fetch --all --prune --no-write-fetch-head --quiet`.
    ///
    /// Honors the user's remotes, credential helpers, and config
    /// (defer-to-git, ADR 0023). `--prune` keeps remote-tracking refs
    /// honest when upstream branches are deleted; skipping
    /// `FETCH_HEAD` avoids churning `.git` (and waking watchers) for
    /// a background operation.
    ///
    /// - Throws: ``GitError`` when the fetch fails (typically network
    ///   or auth). Callers running on a schedule treat that as "try
    ///   again next tick" — ADR 0064's unreachable-remote backoff
    ///   layers above this primitive.
    public func fetchAll(prune: Bool = true) async throws {
        var args = ["fetch", "--all", "--no-write-fetch-head", "--quiet"]
        if prune {
            args.insert("--prune", at: 1)
        }
        _ = try await runner.run(args)
    }

    // MARK: - Branch state

    /// `for-each-ref` format behind ``branchSyncStates()``. TAB
    /// separators for the same reason as `BranchListing.formatString`
    /// (git 2.39 floor lacks `%xNN`; TAB is forbidden in refnames).
    static let syncStateFormat =
        "%(refname:short)\t%(objectname)\t%(upstream)\t%(upstream:short)\t%(upstream:track)\t%(HEAD)"

    /// Snapshot the upstream relationship of every local branch.
    ///
    /// One `git for-each-ref refs/heads/` invocation; no per-branch
    /// process spawns. Branches with no configured upstream have
    /// `upstreamFullRef == nil`; a configured-but-deleted upstream
    /// (e.g. after `fetch --prune` removed the tracking ref) sets
    /// ``BranchSyncState/upstreamGone``.
    public func branchSyncStates() async throws -> [BranchSyncState] {
        let output = try await runner.run([
            "for-each-ref",
            "--format=\(Self.syncStateFormat)",
            "refs/heads/"
        ])
        return try Self.parseSyncStates(output.stdout)
    }

    /// Pure parser for ``branchSyncStates()`` output — split out for
    /// direct unit testing without a fixture repo.
    static func parseSyncStates(_ data: Data) throws -> [BranchSyncState] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitError.parseFailure(
                context: "for-each-ref sync-state output not UTF-8",
                rawSnippet: ""
            )
        }
        var states: [BranchSyncState] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6 else {
                throw GitError.parseFailure(
                    context: "sync-state entry expected 6 TAB-separated fields, got \(fields.count)",
                    rawSnippet: String(line.prefix(120))
                )
            }
            let track = TrackState(parsing: String(fields[4]))
            states.append(BranchSyncState(
                name: String(fields[0]),
                sha: String(fields[1]),
                upstreamFullRef: fields[2].isEmpty ? nil : String(fields[2]),
                upstreamShort: fields[3].isEmpty ? nil : String(fields[3]),
                ahead: track.ahead,
                behind: track.behind,
                upstreamGone: track.gone,
                isCurrent: fields[5] == "*"
            ))
        }
        return states
    }

    /// Parsed `%(upstream:track)` — one of "", "[gone]", "[ahead N]",
    /// "[behind M]", "[ahead N, behind M]". These strings are emitted
    /// verbatim by git (not localized).
    private struct TrackState {
        var ahead = 0
        var behind = 0
        var gone = false

        init(parsing raw: String) {
            guard raw.hasPrefix("["), raw.hasSuffix("]") else { return }
            let inner = raw.dropFirst().dropLast()
            if inner == "gone" {
                gone = true
                return
            }
            for part in inner.split(separator: ",") {
                let token = part.trimmingCharacters(in: .whitespaces)
                if token.hasPrefix("ahead "), let n = Int(token.dropFirst("ahead ".count)) {
                    ahead = n
                } else if token.hasPrefix("behind "), let n = Int(token.dropFirst("behind ".count)) {
                    behind = n
                }
            }
        }
    }

    // MARK: - Fast-forward pull

    /// Fast-forward every local branch that is strictly behind its
    /// upstream, per the ADR 0068 safety table:
    ///
    /// - Not the checked-out branch → ref-only fast-forward via
    ///   `git fetch . <upstream>:<branch>` (git itself refuses non-FF
    ///   updates and branches checked out in *any* worktree).
    /// - The checked-out branch with a clean worktree → `git merge
    ///   --ff-only <upstream>` (updates the working directory).
    /// - The checked-out branch with tracked modifications → skipped
    ///   (``FastForwardOutcome/skippedDirtyWorktree``) unless
    ///   ``FastForwardOptions/autostash`` is set, in which case git's
    ///   `merge --autostash` sets changes aside and re-applies.
    /// - Everything else (diverged / ahead-only / no upstream /
    ///   upstream gone) → typed skip, no mutation.
    ///
    /// Untracked files do not count as "dirty" — a fast-forward never
    /// touches them, and git itself aborts the merge if one would be
    /// overwritten (surfaced as ``FastForwardOutcome/failed(reason:)``).
    public func fastForwardLocalBranches(
        options: FastForwardOptions = FastForwardOptions()
    ) async throws -> [FastForwardResult] {
        let states = try await branchSyncStates()
        var results: [FastForwardResult] = []
        results.reserveCapacity(states.count)
        for state in states {
            let outcome = try await fastForward(state, options: options)
            results.append(FastForwardResult(branch: state.name, outcome: outcome))
        }
        return results
    }

    private func fastForward(
        _ state: BranchSyncState,
        options: FastForwardOptions
    ) async throws -> FastForwardOutcome {
        guard let upstream = state.upstreamFullRef else { return .noUpstream }
        if state.upstreamGone { return .upstreamGone }
        if state.ahead > 0, state.behind > 0 {
            return .diverged(ahead: state.ahead, behind: state.behind)
        }
        if state.ahead > 0 { return .aheadOnly(ahead: state.ahead) }
        guard state.behind > 0 else { return .upToDate }

        if state.isCurrent {
            return try await fastForwardCurrentBranch(state, upstream: upstream, options: options)
        }
        return try await fastForwardRefOnly(state, upstream: upstream)
    }

    /// `git merge --ff-only` for the checked-out branch — the only
    /// path that touches the working directory.
    private func fastForwardCurrentBranch(
        _ state: BranchSyncState,
        upstream: String,
        options: FastForwardOptions
    ) async throws -> FastForwardOutcome {
        let dirty = try await hasTrackedModifications()
        if dirty, !options.autostash {
            return .skippedDirtyWorktree
        }
        var args = ["merge", "--ff-only"]
        if dirty, options.autostash {
            args.append("--autostash")
        }
        args.append(upstream)
        let merge = try await runner.run(args, throwOnNonZero: false)
        guard merge.exitCode == 0 else {
            return .failed(reason: merge.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let head = try await runner.run(["rev-parse", "HEAD"])
        return .fastForwarded(
            from: state.sha,
            to: head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Ref-only fast-forward for a branch that is not checked out
    /// here. `git fetch .` from the local object store: refuses
    /// non-fast-forward updates (no `+` on the refspec) and refuses
    /// branches checked out in any worktree — both refusals surface
    /// as typed skips.
    private func fastForwardRefOnly(
        _ state: BranchSyncState,
        upstream: String
    ) async throws -> FastForwardOutcome {
        let refspec = "\(upstream):refs/heads/\(state.name)"
        let fetch = try await runner.run(["fetch", ".", refspec, "--quiet"], throwOnNonZero: false)
        guard fetch.exitCode == 0 else {
            let stderr = fetch.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.localizedCaseInsensitiveContains("checked out") {
                return .skippedCheckedOutElsewhere
            }
            return .failed(reason: stderr)
        }
        let resolved = try await runner.run(["rev-parse", "refs/heads/\(state.name)"])
        return .fastForwarded(
            from: state.sha,
            to: resolved.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// True when the worktree has *tracked* modifications (any
    /// `git status --porcelain -z` record other than untracked
    /// `?? `). Untracked-only trees are fast-forward-safe; git guards
    /// the overwrite case itself. Internal (not private): the rebase
    /// extension (`SyncOps+Rebase.swift`) applies the same dirty
    /// standard before rewriting.
    func hasTrackedModifications() async throws -> Bool {
        let status = try await runner.run(["status", "--porcelain", "-z"])
        guard let text = String(data: status.stdout, encoding: .utf8) else {
            // Undecodable status output: treat as dirty (fail closed).
            return true
        }
        for record in text.split(separator: "\0") where !record.isEmpty {
            if !record.hasPrefix("?? ") {
                return true
            }
        }
        return false
    }
}

/// The upstream relationship of one local branch, as reported by a
/// single `git for-each-ref` pass.
public struct BranchSyncState: Sendable, Equatable {
    /// Short branch name (`main`, `feature/x`).
    public let name: String
    /// Commit SHA the branch currently points at.
    public let sha: String
    /// Full upstream ref (`refs/remotes/origin/main`, or
    /// `refs/heads/x` for a local-branch upstream); nil when no
    /// upstream is configured.
    public let upstreamFullRef: String?
    /// Short upstream name (`origin/main`); nil when no upstream.
    public let upstreamShort: String?
    /// Commits this branch has that the upstream lacks.
    public let ahead: Int
    /// Commits the upstream has that this branch lacks.
    public let behind: Int
    /// Upstream is configured but its tracking ref no longer exists
    /// (deleted on the remote + pruned).
    public let upstreamGone: Bool
    /// This branch is checked out in *this* worktree.
    public let isCurrent: Bool

    public init(
        name: String,
        sha: String,
        upstreamFullRef: String?,
        upstreamShort: String?,
        ahead: Int,
        behind: Int,
        upstreamGone: Bool,
        isCurrent: Bool
    ) {
        self.name = name
        self.sha = sha
        self.upstreamFullRef = upstreamFullRef
        self.upstreamShort = upstreamShort
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
        self.isCurrent = isCurrent
    }
}

/// Knobs for ``SyncOps/fastForwardLocalBranches(options:)``.
public struct FastForwardOptions: Sendable, Equatable {
    /// Allow fast-forwarding the checked-out branch over a dirty
    /// worktree by letting git `--autostash` around the merge.
    /// Default false (ADR 0068: unattended runs never touch
    /// uncommitted work).
    public var autostash: Bool

    public init(autostash: Bool = false) {
        self.autostash = autostash
    }
}

/// Per-branch outcome of a fast-forward pass.
public struct FastForwardResult: Sendable, Equatable {
    public let branch: String
    public let outcome: FastForwardOutcome

    public init(branch: String, outcome: FastForwardOutcome) {
        self.branch = branch
        self.outcome = outcome
    }
}

/// What happened to one branch during
/// ``SyncOps/fastForwardLocalBranches(options:)``. Everything except
/// ``fastForwarded(from:to:)`` is a non-mutation.
public enum FastForwardOutcome: Sendable, Equatable {
    /// Branch ref moved from `from` to `to` (and, for the checked-out
    /// branch, the working directory updated with it).
    case fastForwarded(from: String, to: String)
    /// Already in sync with upstream.
    case upToDate
    /// Local-only commits exist; nothing to pull. Useful signal for
    /// "you have unpushed work" surfaces.
    case aheadOnly(ahead: Int)
    /// Histories diverged; needs the user's judgment (merge/rebase).
    case diverged(ahead: Int, behind: Int)
    /// No upstream configured for this branch.
    case noUpstream
    /// Upstream configured but deleted on the remote (post-prune).
    case upstreamGone
    /// Checked-out branch with tracked modifications and
    /// `autostash` off.
    case skippedDirtyWorktree
    /// Branch is checked out in another linked worktree; git refused
    /// the ref update.
    case skippedCheckedOutElsewhere
    /// git refused or errored; `reason` carries its stderr.
    case failed(reason: String)
}
