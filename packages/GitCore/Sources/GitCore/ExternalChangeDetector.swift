// ExternalChangeDetector.swift
//
// ADR 0088 — the detection half of the agent-review surface. Given a
// worktree, answer "what changed here that Sprig did NOT author?" — the
// commits an outside process (a terminal, an AI coding agent, a
// teammate's tooling) introduced, plus whether HEAD itself was moved to
// a *different existing commit* by someone other than Sprig.
//
// Two signals, both leaning on ``OperationProvenance`` (the "did Sprig
// author this?" record):
//
//   1. **External commits.** `git log` a range (default: everything
//      reachable from the current ref but not from the last ref state
//      Sprig checkpointed), then ``OperationProvenance/externalCommits(among:)``
//      filters to the commits Sprig never recorded authoring. Those are
//      the reviewable set.
//   2. **HEAD moved elsewhere.** Compare the current ref→SHA state
//      against ``OperationProvenance/lastKnownHeads()``. When `HEAD`'s
//      branch points at a *different existing commit* than Sprig last
//      checkpointed — and Sprig didn't author the new tip — HEAD was
//      moved from outside (a `reset`, `checkout`, force-update, etc.).
//
// Pure and testable: no view-model state, no UI. All git access via
// ``Runner``; Tier 1, portable. The agent-review VM (TaskWindowKit) and
// the live watcher (AgentKit, a documented follow-up) consume this.

import Foundation

/// A commit an outside process introduced — the unit the agent-review
/// surface (ADR 0088) lets the user review, stage, or split.
public struct ExternalCommit: Sendable, Equatable {
    /// Full commit object id.
    public let sha: String
    /// First-line summary (`%s`).
    public let subject: String
    /// Author identity, for the "who made this?" affordance.
    public let author: Identity
    /// Author timestamp.
    public let authorDate: Date

    public init(sha: String, subject: String, author: Identity, authorDate: Date) {
        self.sha = sha
        self.subject = subject
        self.author = author
        self.authorDate = authorDate
    }
}

/// How `HEAD` moved relative to the ref state Sprig last checkpointed.
public enum HeadMovement: Sendable, Equatable {
    /// `HEAD`'s ref is at the same SHA Sprig last recorded — no
    /// external move (the common steady-state case), or Sprig has never
    /// checkpointed this ref so there's no baseline to compare against.
    case unchanged
    /// `HEAD`'s ref points at a *different existing commit* than Sprig
    /// last checkpointed, and Sprig did not author the new tip — an
    /// outside process moved it (reset / checkout / force-update). The
    /// associated values are the SHA Sprig last knew and the current
    /// SHA, so the UI can offer "go back to where Sprig left it".
    case movedExternally(from: String, to: String)
}

/// The external-change picture for one worktree at one moment.
public struct ExternalChangeReport: Sendable, Equatable {
    /// Externally-authored commits in the scanned range, newest first
    /// (the order `git log` returns).
    public let commits: [ExternalCommit]
    /// Whether `HEAD` itself was moved by an outside process.
    public let headMovement: HeadMovement

    public init(commits: [ExternalCommit], headMovement: HeadMovement) {
        self.commits = commits
        self.headMovement = headMovement
    }

    /// True when there is anything for the user to review — external
    /// commits, an external HEAD move, or both.
    public var hasExternalChange: Bool {
        if !commits.isEmpty { return true }
        if case .movedExternally = headMovement { return true }
        return false
    }
}

/// Detects externally-authored change in one worktree (ADR 0088).
///
/// Pure read-only engine — it lists and classifies; it never mutates
/// the repo. `Sendable` value type; one per worktree (the wrapped
/// ``Runner`` carries the working directory).
public struct ExternalChangeDetector: Sendable {
    public let runner: Runner
    private let provenance: OperationProvenance

    public init(runner: Runner) {
        self.runner = runner
        provenance = OperationProvenance(runner: runner)
    }

    /// The symbolic ref `HEAD` resolves to (e.g. `refs/heads/main`), or
    /// nil on a detached HEAD. Used to key the HEAD-movement check into
    /// the same ref name ``OperationProvenance/recordHeads(_:)`` stored.
    private func headRefName() async throws -> String? {
        let result = try await runner.run(
            ["symbolic-ref", "--quiet", "HEAD"],
            throwOnNonZero: false
        )
        guard result.exitCode == 0 else { return nil }
        let name = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The current SHA of `revspec`, or nil if it doesn't resolve (an
    /// unborn branch, a missing ref).
    private func resolve(_ revspec: String) async throws -> String? {
        let result = try await runner.run(
            ["rev-parse", "--verify", "--quiet", revspec],
            throwOnNonZero: false
        )
        guard result.exitCode == 0 else { return nil }
        let sha = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// List the commits in `range` (a `git log` revision range like
    /// `<base>..<tip>`, or a single revspec) and keep only those Sprig
    /// did not author — the externally-authored set.
    ///
    /// Order is newest-first (the order `git log` returns). The range is
    /// passed verbatim to `git log`, so callers control scope: a bounded
    /// `A..B`, `HEAD` for the whole reachable history, etc.
    public func externalCommits(in range: String) async throws -> [ExternalCommit] {
        let output = try await runner.run([
            "log",
            "-z",
            "--format=\(LogParser.formatString)",
            range
        ])
        let commits = try LogParser.parse(output.stdout)
        let externalSHAs = try await provenance.externalCommits(among: commits.map(\.sha))
        let externalSet = Set(externalSHAs)
        return commits
            .filter { externalSet.contains($0.sha) }
            .map {
                ExternalCommit(
                    sha: $0.sha,
                    subject: $0.subject,
                    author: $0.author,
                    authorDate: $0.authorDate
                )
            }
    }

    /// Whether `HEAD` was moved to a different existing commit by an
    /// outside process since Sprig last checkpointed the ref state.
    ///
    /// Returns ``HeadMovement/unchanged`` when: HEAD is detached, the
    /// ref is unborn, Sprig has no checkpoint for this ref, the ref is
    /// still at the checkpointed SHA, or the new tip is one Sprig
    /// authored (so the move was Sprig's own work — a commit, not an
    /// external reset). Only a move to a *different* commit Sprig didn't
    /// make reads as ``HeadMovement/movedExternally(from:to:)``.
    public func headMovement() async throws -> HeadMovement {
        guard let ref = try await headRefName(),
              let current = try await resolve(ref)
        else { return .unchanged }

        let lastKnown = try await provenance.lastKnownHeads()
        guard let recorded = lastKnown[ref], recorded != current else {
            return .unchanged
        }
        // The ref moved. Suppress it as Sprig's own work ONLY for a
        // forward move: Sprig authored the new tip AND it descends from
        // the checkpoint (a commit advancing HEAD). An external *rewind*
        // — `reset`/`checkout` back onto an older commit Sprig happened
        // to author earlier — must still read as external: authorship of
        // the commit object does not mean Sprig moved HEAD here. Without
        // the ancestor check, `authored.contains(current)` alone would
        // false-negative a reset onto any old Sprig commit (the scan
        // range `recorded..HEAD` is also empty there, so neither signal
        // would fire).
        let authored = try await provenance.authoredCommits()
        if authored.contains(current),
           try await isAncestor(recorded, of: current)
        {
            return .unchanged
        }
        return .movedExternally(from: recorded, to: current)
    }

    /// Whether `ancestor` is an ancestor of (or equal to) `descendant`.
    /// `git merge-base --is-ancestor` exits 0 when it is, 1 when not.
    private func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        let result = try await runner.run(
            ["merge-base", "--is-ancestor", ancestor, descendant],
            throwOnNonZero: false
        )
        return result.exitCode == 0
    }

    /// Build the full external-change report for the worktree.
    ///
    /// Scope: when Sprig has a checkpoint for the current branch, the
    /// commit range is `<checkpointed-sha>..HEAD` (everything that
    /// arrived on this branch since Sprig last looked); otherwise it
    /// falls back to `HEAD` (the whole reachable history is candidate —
    /// provenance still filters out anything Sprig authored). The
    /// HEAD-movement signal rides alongside.
    public func report() async throws -> ExternalChangeReport {
        // Unborn branch / empty repo: HEAD doesn't resolve, so there is
        // nothing committed to review. Return a clean empty report rather
        // than letting `git log HEAD` fail (exit 128) and surfacing a hard
        // error in the Review window — matching how headMovement()/resolve()
        // already treat the no-commit case as the normal `.unchanged`/nil.
        guard try await resolve("HEAD") != nil else {
            return ExternalChangeReport(commits: [], headMovement: .unchanged)
        }
        let movement = try await headMovement()
        let range = try await scanRange()
        let commits = try await externalCommits(in: range)
        return ExternalChangeReport(commits: commits, headMovement: movement)
    }

    /// The `git log` range ``report()`` scans: `<checkpoint>..HEAD` when
    /// a checkpoint for the current branch exists and still resolves,
    /// else `HEAD`.
    private func scanRange() async throws -> String {
        guard let ref = try await headRefName(),
              let recorded = try await provenance.lastKnownHeads()[ref],
              try await resolve(recorded) != nil
        else { return "HEAD" }
        return "\(recorded)..HEAD"
    }
}
