// StashOps+Browse.swift
//
// ADR 0079 — the stash *browser* primitives behind the Stash task
// window: list every set-aside entry, apply/pop a specific one, drop
// one. ADR 0069's push/pop-the-top primitives live in StashOps.swift;
// this file adds the by-ref verbs a browsing surface needs.
//
// The same plumbing-over-messages discipline applies: outcomes are
// detected via ref/reflog state, not by parsing git's human output.
// `list` uses NUL-delimited `--format` fields so subjects with
// unusual characters can't break the parse; a conflicted `pop <ref>`
// is detected by non-zero exit PLUS the entry's commit SHA still
// appearing in the stash reflog (reflog *indices* shift when entries
// drop, so SHA — not `stash@{N}` — is the stable identity).

import Foundation

/// One entry from `git stash list`, newest first.
public struct StashEntry: Sendable, Equatable {
    /// Reflog selector at the time of listing, e.g. `stash@{0}` —
    /// the handle the by-ref verbs take. **Indices shift** when
    /// entries are popped or dropped; ``sha`` is the stable identity.
    public let ref: String
    /// The stash commit's SHA. Stable across reindexing — safety
    /// copies (ADR 0033) point here.
    public let sha: String
    /// When the entry was created (the stash commit's committer
    /// date). `nil` only if git emits an unparseable date.
    public let createdAt: Date?
    /// Subject line, e.g. `On main: set aside before switching`.
    public let subject: String

    public init(ref: String, sha: String, createdAt: Date?, subject: String) {
        self.ref = ref
        self.sha = sha
        self.createdAt = createdAt
        self.subject = subject
    }
}

/// Result of ``StashOps/apply(_:)``.
public enum StashApplyOutcome: Sendable, Equatable {
    /// Applied cleanly. Unlike pop, the entry is **kept** — apply
    /// never drops.
    case applied
    /// Applying conflicted (or was blocked by local changes);
    /// `detail` carries git's explanation. The entry is kept and the
    /// worktree may hold conflict markers to resolve.
    case conflicted(detail: String)
}

public extension StashOps {
    /// `git stash list`, parsed from NUL-delimited fields
    /// (`%gd%x00%H%x00%cI%x00%s` — selector, SHA, ISO-8601 committer
    /// date, subject; one line per entry, newest first).
    func list() async throws -> [StashEntry] {
        let result = try await runner.run([
            "stash", "list", "--format=%gd%x00%H%x00%cI%x00%s"
        ])
        return Self.parseList(result.stdoutString)
    }

    /// `git stash apply <ref>` — re-apply a specific entry *without*
    /// dropping it.
    ///
    /// - Returns: ``StashApplyOutcome/applied`` on a clean apply, or
    ///   ``StashApplyOutcome/conflicted(detail:)`` when git exited
    ///   non-zero (conflict markers, or a blocked apply over local
    ///   changes) — either way the entry survives, because apply
    ///   never drops.
    /// - Throws: ``GitError`` when `ref` doesn't resolve to a stash
    ///   entry (e.g. a stale index after a drop elsewhere).
    func apply(_ ref: String) async throws -> StashApplyOutcome {
        _ = try await resolveEntrySHA(ref)
        let result = try await runner.run(["stash", "apply", ref], throwOnNonZero: false)
        if result.exitCode == 0 {
            return .applied
        }
        return .conflicted(detail: Self.explanation(from: result))
    }

    /// `git stash pop <ref>` — apply a *specific* entry and drop it
    /// on success. The no-argument top-of-stack variant lives in
    /// ``StashOps/pop()`` (ADR 0069).
    ///
    /// - Returns: ``StashPopOutcome/applied`` when the entry applied
    ///   cleanly (and was dropped), or
    ///   ``StashPopOutcome/keptDueToConflict(detail:)`` when git
    ///   exited non-zero and the entry's commit verifiably survives
    ///   in the stash reflog.
    /// - Throws: ``GitError`` when `ref` doesn't resolve, or when a
    ///   failed pop did NOT keep the entry (never observed;
    ///   defensive).
    func pop(_ ref: String) async throws -> StashPopOutcome {
        let sha = try await resolveEntrySHA(ref)
        let result = try await runner.run(["stash", "pop", ref], throwOnNonZero: false)
        if result.exitCode == 0 {
            return .applied
        }
        guard try await stashCommitSHAs().contains(sha) else {
            throw GitError.nonZeroExit(
                command: ["stash", "pop", ref],
                exitCode: result.exitCode,
                stderr: result.stderrString,
                stdout: result.stdoutString
            )
        }
        return .keptDueToConflict(detail: Self.explanation(from: result))
    }

    /// `git stash drop <ref>`.
    ///
    /// Dropping makes the entry's commit unreachable (stash reflog
    /// entries don't linger the way branch reflogs do), so callers
    /// wanting an undo must write a safety ref to the returned SHA
    /// **before** calling this — the Stash view model does, per
    /// ADR 0033's medium tier.
    ///
    /// - Returns: the dropped entry's commit SHA.
    /// - Throws: ``GitError`` when `ref` doesn't resolve.
    @discardableResult
    func drop(_ ref: String) async throws -> String {
        let sha = try await resolveEntrySHA(ref)
        _ = try await runner.run(["stash", "drop", ref])
        return sha
    }

    // MARK: - Internals

    /// Resolve a `stash@{N}` selector to its commit SHA, throwing the
    /// underlying git error when it doesn't resolve (out-of-range
    /// index, no stash at all).
    private func resolveEntrySHA(_ ref: String) async throws -> String {
        let result = try await runner.run(
            ["rev-parse", "--quiet", "--verify", ref],
            throwOnNonZero: false
        )
        guard result.exitCode == 0 else {
            throw GitError.nonZeroExit(
                command: ["rev-parse", "--quiet", "--verify", ref],
                exitCode: result.exitCode,
                stderr: result.stderrString.isEmpty
                    ? "unknown stash entry: \(ref)"
                    : result.stderrString,
                stdout: result.stdoutString
            )
        }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every stash entry's commit SHA — the survival check for
    /// conflicted pops (selector indices shift; SHAs don't).
    private func stashCommitSHAs() async throws -> Set<String> {
        let result = try await runner.run(["stash", "list", "--format=%H"])
        return Set(result.stdoutString.split(separator: "\n").map(String.init))
    }

    private static func parseList(_ raw: String) -> [StashEntry] {
        let formatter = ISO8601DateFormatter()
        return raw.split(separator: "\n").compactMap { line in
            let fields = line.split(
                separator: "\u{0}",
                maxSplits: 3,
                omittingEmptySubsequences: false
            )
            guard fields.count == 4 else { return nil }
            return StashEntry(
                ref: String(fields[0]),
                sha: String(fields[1]),
                createdAt: formatter.date(from: String(fields[2])),
                subject: String(fields[3])
            )
        }
    }

    /// Prefer stderr's explanation, fall back to stdout (git splits
    /// its conflict narration across both).
    private static func explanation(from result: Runner.Output) -> String {
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
