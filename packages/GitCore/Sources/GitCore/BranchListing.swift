// BranchListing.swift
//
// Parser for `git for-each-ref refs/heads/` output produced with
// ``BranchListing/formatString``. Entries are newline-terminated
// (unlike ``LogParser`` which uses `-z` — `git for-each-ref` doesn't
// accept `-z`); fields within an entry are TAB-separated.
//
// **Why TAB, not `%x1f` like everywhere else.** `git for-each-ref`
// only learned the `%xNN` byte-literal format atom in git 2.46, but
// the project's minimum-supported git version is 2.39 (Apple-bundled
// on macOS 14 per ADR 0047). We need a byte that git emits literally
// AND that `git check-ref-format` forbids in refnames AND that won't
// appear in the SHA-only and `*`/space `HEAD` fields. ASCII control
// chars (incl. TAB at 0x09) and newlines are forbidden in refnames
// per `git check-ref-format`. TAB satisfies all three requirements and
// is a single character — keeps the parser tight and the format
// string readable.
//
// The format mixes refname (short + full), the commit SHA the ref
// points at, and a `HEAD` indicator so the caller knows which branch
// is current without a separate `git rev-parse HEAD` invocation.
//
// To invoke the matching git command:
//
// ```
// git for-each-ref --format=<BranchListing.formatString> refs/heads/
// ```
//
// The output is ordered by `git for-each-ref`'s default sort
// (`refname:strip=2` since we're scoped to `refs/heads/`), which is
// effectively alphabetical. Callers that want recency-first ordering
// (per `branch.sort=-committerdate`, ADR 0026) pass `--sort` themselves.

import Foundation

/// Pure parser for `git for-each-ref refs/heads/ -z --format=…` output.
/// No git invocation here; the caller spawns git via ``Runner`` and
/// hands the raw `Data` to ``parse(_:)``.
public enum BranchListing {
    /// Format string matching what ``parse(_:)`` expects. Fields, in
    /// order: short refname (`feature/x`), full refname
    /// (`refs/heads/feature/x`), commit SHA, `HEAD` marker (`*` for the
    /// currently-checked-out branch, space otherwise). Separated by
    /// literal TABs (`\t`) — `git check-ref-format` forbids TABs in
    /// refnames so the split is unambiguous.
    public static let formatString = "%(refname:short)\t%(refname)\t%(objectname)\t%(HEAD)"

    /// Parse the raw bytes of `git for-each-ref refs/heads/
    /// --format=<formatString>` into an ordered array of branches.
    ///
    /// Returns an empty array for an empty input (a fresh repo with no
    /// commits — `git for-each-ref` emits nothing in that case). Throws
    /// ``GitError/parseFailure`` if any entry is malformed.
    public static func parse(_ data: Data) throws -> [Branch] {
        var branches: [Branch] = []
        var index = data.startIndex
        let newline: UInt8 = 0x0A

        while index < data.endIndex {
            let entryEnd = data[index...].firstIndex(of: newline) ?? data.endIndex
            let slice = data[index ..< entryEnd]
            if !slice.isEmpty {
                try branches.append(parseEntry(Data(slice)))
            }
            index = entryEnd < data.endIndex ? data.index(after: entryEnd) : data.endIndex
        }
        return branches
    }

    private static func parseEntry(_ entry: Data) throws -> Branch {
        let tab: UInt8 = 0x09
        let fields = entry.split(
            separator: tab,
            omittingEmptySubsequences: false
        )
        guard fields.count == 4 else {
            let snippet = String(data: entry.prefix(80), encoding: .utf8) ?? "<non-UTF-8>"
            throw GitError.parseFailure(
                context: "branch entry expected 4 TAB-separated fields, got \(fields.count)",
                rawSnippet: snippet
            )
        }
        guard
            let short = String(data: Data(fields[0]), encoding: .utf8),
            let full = String(data: Data(fields[1]), encoding: .utf8),
            let sha = String(data: Data(fields[2]), encoding: .utf8),
            let headMarker = String(data: Data(fields[3]), encoding: .utf8)
        else {
            throw GitError.parseFailure(
                context: "branch entry contained non-UTF-8 bytes",
                rawSnippet: "<non-UTF-8>"
            )
        }
        // git for-each-ref's %(HEAD) emits "*" for the checked-out
        // branch and " " (space) for the rest. We accept either "*" or
        // "" (stripped) as the trigger, since shell/dialog variants
        // could collapse the lone-space value.
        let isHead = headMarker.trimmingCharacters(in: .whitespaces) == "*"
        return Branch(shortName: short, fullName: full, sha: sha, isHead: isHead)
    }
}

/// A single local branch as surfaced by `git for-each-ref refs/heads/`.
///
/// Wire-stable: this type appears in `RepoState` queries, in
/// `TaskWindowKit` view models, and in the `IPCSchema` envelope shapes
/// that surface branch info to the FinderSync / Explorer extensions.
public struct Branch: Sendable, Equatable, Hashable {
    /// Short form (e.g. `main`, `feature/x`). The form users see in the
    /// UI and the form `git switch <name>` accepts.
    public let shortName: String

    /// Full refname (e.g. `refs/heads/feature/x`). Useful when
    /// distinguishing branches from tags or remote-tracking refs.
    public let fullName: String

    /// Commit SHA the branch points at.
    public let sha: String

    /// True iff this branch is the currently-checked-out branch
    /// (HEAD resolves to it). Detached-HEAD repos have no branch with
    /// `isHead == true`.
    public let isHead: Bool

    public init(shortName: String, fullName: String, sha: String, isHead: Bool) {
        self.shortName = shortName
        self.fullName = fullName
        self.sha = sha
        self.isHead = isHead
    }
}
