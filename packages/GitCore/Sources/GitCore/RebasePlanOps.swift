// RebasePlanOps.swift
//
// ADR 0083 — the interactive-rebase ENGINE (M5 substrate; ADR 0051's
// stacked workflows build on it): execute a reorder/fold/drop plan
// over the unpushed range, deferring the entire rebase state machine
// to git's own sequencer.
//
// How the todo gets in: `git rebase -i` with a one-shot
// `sequence.editor` whose command is a `printf` that writes our todo
// over git's — no shipped scripts, works wherever git's own sh does
// (git invokes editors through sh on every platform, including Git
// for Windows' bundled sh). The interpolated todo lines are strictly
// `<verb> <40-hex-sha>` — validated upstream, so the editor command
// needs no quoting and can't be injected.
//
// The editor-free verb set (v1): PICK, FIXUP, DROP (+ reordering by
// todo order). `squash`/`reword` open git's COMMIT editor mid-run —
// they ride ADR 0082's reword / a later slice; `fixup` folds without
// an editor and covers the "absorb these WIP commits" need.
//
// Safety contract (same as ADR 0082): unpushed only, no staged
// changes, no parked midstream op, clean tracked worktree, on a
// branch. A conflicted replay PARKS git's own rebase — the M4
// resolver owns continue/abort, and `rebase --abort` returns to the
// exact pre-plan tip (test-pinned). Callers pair with an ADR 0033
// medium-tier snapshot first (the RebasePlanViewModel does).

import Foundation

/// One commit in the rewritable range, oldest first (todo order —
/// git replays oldest → newest).
public struct UnpushedCommit: Sendable, Equatable {
    public let sha: String
    public let subject: String

    public init(sha: String, subject: String) {
        self.sha = sha
        self.subject = subject
    }
}

/// One todo line of a ``RebasePlan`` execution.
public struct RebaseStep: Sendable, Equatable {
    public enum Verb: String, Sendable {
        /// Replay the commit as-is.
        case pick
        /// Fold the commit into the previous picked one, keeping the
        /// previous commit's message (no editor involved).
        case fixup
        /// Leave the commit out.
        case drop
    }

    public let verb: Verb
    /// Full 40-hex SHA of an unpushed commit.
    public let sha: String

    public init(_ verb: Verb, _ sha: String) {
        self.verb = verb
        self.sha = sha
    }
}

/// Result of ``RebasePlanOps/apply(_:)``.
public enum RebasePlanOutcome: Sendable, Equatable {
    /// The plan replayed cleanly; HEAD is `newTip`.
    case completed(newTip: String)
    /// The replay hit conflicts and git's rebase is PARKED — the
    /// resolver owns continue/abort; `git rebase --abort` returns to
    /// the pre-plan tip.
    case conflicted(conflictedPathCount: Int)
    /// The plan isn't a valid rewrite of the unpushed range (the
    /// reason is diagnostic detail; UIs word it generically).
    case invalidPlan(reason: String)
    /// Nothing unpushed to rebase (everything is on a remote, or
    /// there are no commits at all).
    case refusedNothingToRebase
    case refusedMidstream
    case refusedStagedChanges
    case refusedDirtyWorktree
    case refusedDetachedHEAD
    /// The rebase failed outright and the repo was left untouched
    /// (no rebase markers) — `reason` carries git's stderr.
    case failed(reason: String)
}

/// Plan-driven history rewriting for one repository.
public struct RebasePlanOps: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    /// The rewritable range, oldest first (todo order). Empty when
    /// every commit is on a remote — or when there are no commits.
    public func unpushedCommits() async throws -> [UnpushedCommit] {
        let result = try await runner.run(
            ["log", "--reverse", "--format=%H%x00%s", "HEAD", "--not", "--remotes"],
            throwOnNonZero: false
        )
        guard result.exitCode == 0 else { return [] }
        return result.stdoutString.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return UnpushedCommit(sha: String(fields[0]), subject: String(fields[1]))
        }
    }

    /// Execute `plan` over the unpushed range.
    ///
    /// The plan must cover each unpushed commit exactly once (drops
    /// are explicit, never implicit) and may not start with a fixup
    /// (there is no previous commit to fold into). An all-drop plan
    /// is valid: the branch ends at the shared base.
    public func apply(_ plan: [RebaseStep]) async throws -> RebasePlanOutcome {
        if let refusal = try await guardRefusal() { return refusal }
        let unpushed = try await unpushedCommits()
        guard !unpushed.isEmpty else { return .refusedNothingToRebase }
        if let invalid = Self.validate(plan: plan, against: unpushed) {
            return .invalidPlan(reason: invalid)
        }

        // Base of the rewrite: the parent of the oldest unpushed
        // commit — or git's --root when the range reaches the very
        // first commit (a repo with no remotes rewrites everything).
        let baseArgs = if try await resolves("HEAD~\(unpushed.count)") {
            ["HEAD~\(unpushed.count)"]
        } else {
            ["--root"]
        }

        let todo = plan
            .map { "\($0.verb.rawValue) \($0.sha)" }
            .joined(separator: "\\n") + "\\n"
        let editor = "printf '\(todo)' >\"$1\""
        let rebase = try await runner.run(
            ["-c", "sequence.editor=\(editor)", "rebase", "-i"] + baseArgs,
            throwOnNonZero: false
        )
        if rebase.exitCode == 0 {
            return try await .completed(newTip: headSHA())
        }

        // Non-zero: conflict (rebase parked for the resolver) vs
        // outright failure (repo untouched) — the marker files are
        // the discriminator, same as SyncOps' rebase leg.
        let worktree = runner.defaultWorkingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
        if MidstreamOperation.detectFromMarkers(gitDirURL: gitDir) == .rebase {
            let unmerged = try await runner.run(["ls-files", "-u", "-z"])
            let paths = try Set(UnmergedListing.parse(unmerged.stdout).map(\.path))
            return .conflicted(conflictedPathCount: paths.count)
        }
        return .failed(
            reason: rebase.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Validation

    /// nil when valid; otherwise the diagnostic reason.
    static func validate(plan: [RebaseStep], against unpushed: [UnpushedCommit]) -> String? {
        let hexDigits = Set("0123456789abcdef")
        for step in plan {
            guard step.sha.count == 40, step.sha.allSatisfy(hexDigits.contains) else {
                return "step SHA is not 40-hex lowercase: '\(step.sha)'"
            }
        }
        let planSHAs = plan.map(\.sha)
        let unpushedSHAs = unpushed.map(\.sha)
        guard planSHAs.sorted() == unpushedSHAs.sorted(),
              Set(planSHAs).count == planSHAs.count
        else {
            return "plan must cover each unpushed commit exactly once"
        }
        let firstKept = plan.first { $0.verb != .drop }
        if firstKept?.verb == .fixup {
            return "a fixup needs a previous picked commit to fold into"
        }
        return nil
    }

    // MARK: - Guards (ADR 0082's set + the dirty-worktree refusal a

    // worktree-touching replay needs)

    private func guardRefusal() async throws -> RebasePlanOutcome? {
        let common = try await HistoryRewriteGuards(runner: runner).firstRefusal(
            requireExistingHEAD: false,
            refuseDirtyWorktree: true
        )
        switch common {
        case .detachedHEAD: return .refusedDetachedHEAD
        case .midstream: return .refusedMidstream
        case .stagedChanges: return .refusedStagedChanges
        case .dirtyWorktree: return .refusedDirtyWorktree
        // Unborn HEAD surfaces as an empty unpushed range
        // (refusedNothingToRebase) — not requested here.
        case .noCommits: return .refusedNothingToRebase
        case nil: return nil
        }
    }

    private func resolves(_ rev: String) async throws -> Bool {
        let result = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "\(rev)^{commit}"],
            throwOnNonZero: false
        )
        return result.exitCode == 0
    }

    private func headSHA() async throws -> String {
        try await runner.run(["rev-parse", "HEAD"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
