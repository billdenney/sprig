// MidstreamOperation.swift
//
// Detection + classification of which "midstream" git operation a
// repo is currently in — the operations that can leave the working
// tree in a half-applied, conflict-bearing state until the user
// resolves and `--continue`s (or `--abort`s) them.
//
// The M4 MergeConflictResolverViewModel uses this to dispatch the
// right `git <op> --continue` / `--abort` invocation per state. The
// surface is in GitCore so other consumers (sprigctl, future task
// windows that show "what's going on" banners) can ask the same
// question without reimplementing the marker-file walk.
//
// Wire format (per git's source-tree layout):
//   - merge:       <gitDir>/MERGE_HEAD exists
//   - rebase:      <gitDir>/rebase-merge/ or rebase-apply/ exists
//                  (with rebase-apply/applying ABSENT, which
//                  distinguishes from `git am`)
//   - cherry-pick: <gitDir>/CHERRY_PICK_HEAD exists
//   - revert:      <gitDir>/REVERT_HEAD exists
//   - am:          <gitDir>/rebase-apply/applying exists
//
// Multiple markers can theoretically co-exist, but in practice git
// only writes one set at a time. ``MidstreamOperation/detect(repoURL:runner:)``
// returns the first match in declared priority order
// (merge → rebase → cherryPick → revert → am).

import Foundation

/// Which "midstream" git operation a repo is currently mid-flight on,
/// or `none` for a clean state.
///
/// Each non-`none` case names the operation whose `--continue` and
/// `--abort` flags the agent should invoke to finish or abandon the
/// op. The associated `git` argv lives on the enum so consumers
/// don't reinvent the dispatch.
public enum MidstreamOperation: Sendable, Equatable, Hashable, CaseIterable {
    /// No midstream operation. `git status` would report a clean
    /// merge / rebase / etc. state.
    case none

    /// `git merge` in progress (conflicts left after a non-FF merge).
    case merge

    /// `git rebase` in progress — either interactive (rebase-merge/)
    /// or non-interactive (rebase-apply/).
    case rebase

    /// `git cherry-pick` in progress.
    case cherryPick

    /// `git revert` in progress.
    case revert

    /// `git am` in progress (applying a mailbox of patches).
    case am

    /// The `git` subcommand argv that completes this operation.
    /// `nil` for ``MidstreamOperation/none``.
    ///
    /// Example: `.merge.continueArguments == ["commit", "--no-edit"]`
    /// (merges complete by writing the merge commit, not by `git
    /// merge --continue` — git itself recommends the explicit
    /// commit invocation for that case).
    public var continueArguments: [String]? {
        switch self {
        case .none: nil
        case .merge: ["commit", "--no-edit"]
        case .rebase: ["rebase", "--continue"]
        case .cherryPick: ["cherry-pick", "--continue"]
        case .revert: ["revert", "--continue"]
        case .am: ["am", "--continue"]
        }
    }

    /// The `git` subcommand argv that abandons this operation.
    /// `nil` for ``MidstreamOperation/none``.
    public var abortArguments: [String]? {
        switch self {
        case .none: nil
        case .merge: ["merge", "--abort"]
        case .rebase: ["rebase", "--abort"]
        case .cherryPick: ["cherry-pick", "--abort"]
        case .revert: ["revert", "--abort"]
        case .am: ["am", "--abort"]
        }
    }

    /// User-presentable label for this op. The MergeConflictResolver
    /// task window uses this in its "Resolving <op> conflicts" header.
    public var displayLabel: String {
        switch self {
        case .none: "no operation"
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        case .am: "am"
        }
    }

    // MARK: - Detection

    /// Probe the repo for an active midstream operation. Resolves
    /// `<gitDir>` via `git rev-parse --git-dir` (so worktrees and
    /// linked-worktree gitdirs are handled correctly) and inspects
    /// the marker files. Returns ``MidstreamOperation/none`` when
    /// the repo is clean.
    ///
    /// `repoURL` is the working directory git is being invoked
    /// against — typically the same as the `runner`'s
    /// `defaultWorkingDirectory`. The caller passes it explicitly so
    /// the function works against runners that don't have a default
    /// configured.
    ///
    /// Throws ``GitError`` from the underlying `git rev-parse`
    /// invocation if the path isn't inside a git repo.
    public static func detect(repoURL: URL, runner: Runner) async throws -> MidstreamOperation {
        let output = try await runner.run(["rev-parse", "--git-dir"])
        let raw = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw GitError.parseFailure(
                context: "`git rev-parse --git-dir` returned an empty path",
                rawSnippet: raw
            )
        }
        // `git rev-parse --git-dir` returns either an absolute path
        // (linked worktrees) or a relative path (typical case from
        // the repo root). Resolve relative paths against `repoURL`.
        let gitDirURL: URL = if (raw as NSString).isAbsolutePath {
            URL(fileURLWithPath: raw)
        } else {
            repoURL.appendingPathComponent(raw)
        }
        return detectFromMarkers(gitDirURL: gitDirURL)
    }

    /// Detection based purely on filesystem-marker presence at a
    /// resolved `<gitDir>` URL. Exposed `internal` so tests can hand
    /// a synthesized marker layout without going through `git
    /// rev-parse`.
    static func detectFromMarkers(gitDirURL: URL) -> MidstreamOperation {
        let fm = FileManager.default
        func exists(_ component: String) -> Bool {
            fm.fileExists(atPath: gitDirURL.appendingPathComponent(component).path)
        }
        // am is detected by `rebase-apply/applying` — must be tested
        // BEFORE the generic rebase check (which would otherwise
        // claim the rebase-apply/ dir as a plain rebase).
        if exists("rebase-apply/applying") { return .am }
        if exists("MERGE_HEAD") { return .merge }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return .none
    }
}
