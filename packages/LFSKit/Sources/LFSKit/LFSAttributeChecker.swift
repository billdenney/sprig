// LFSAttributeChecker.swift
//
// Authoritative "is this path LFS-tracked?" via `git check-attr`. Where
// L1 (`LFSPointer`) handles content-on-disk and L2
// (`GitAttributesLFSParser`) handles the rules text, this slice
// handles the actual matching — but defers to git itself rather than
// reimplementing gitignore-style globs.
//
// Why defer to git: the `.gitattributes` pattern syntax has the same
// corner cases as `.gitignore` (path-anchored vs name-anchored,
// `**`, character classes, negation interactions), and git's
// implementation is the source of truth. A pure-Swift fnmatch is a
// possible follow-up, but every real consumer of "LFS-tracked?" is
// already running inside or alongside a git invocation, so this
// wrapper is the path of least surprise.
//
// Tier 1; depends only on GitCore (Tier 1) for `Runner`.

import Foundation
import GitCore

/// One `git check-attr filter <path>` result row.
public struct LFSCheckAttrResult: Equatable, Hashable, Sendable {
    public let path: String

    /// The `filter` attribute git reports for this path. Common
    /// values: `"lfs"` (LFS-tracked), `"unspecified"` (no rule
    /// matched), `"unset"` (explicit `!filter` rule). Other values
    /// are possible if the user has configured a custom filter
    /// driver.
    public let filter: String

    /// True iff `filter == "lfs"`. The convenience for the common
    /// callsite — every consumer wants this boolean and only a
    /// minority cares about the distinction between "unspecified"
    /// and "unset".
    public var isLFS: Bool {
        filter == "lfs"
    }

    public init(path: String, filter: String) {
        self.path = path
        self.filter = filter
    }
}

/// Static wrapper around `git check-attr -z --stdin filter`. Stateless;
/// the `runner` argument carries everything (cwd, env, RunnerLog).
public enum LFSAttributeChecker {
    /// Ask git which of `paths` are LFS-tracked, per the repo's
    /// `.gitattributes` (and any chained / global / inherited rules
    /// git considers).
    ///
    /// Returns one ``LFSCheckAttrResult`` per input path, in the
    /// same order. Empty input → empty output (no git invocation).
    ///
    /// `paths` are passed via stdin with NUL separators, so they may
    /// contain spaces, colons, or other characters that would be
    /// ambiguous on a command line.
    public static func check(paths: [String], runner: Runner) async throws -> [LFSCheckAttrResult] {
        guard !paths.isEmpty else { return [] }
        let stdin = encodeStdin(paths: paths)
        let output = try await runner.run(
            ["check-attr", "-z", "--stdin", "filter"],
            stdin: stdin
        )
        return parse(output.stdout)
    }

    /// Build the NUL-separated stdin payload `git check-attr -z
    /// --stdin` expects. Each path is emitted as its UTF-8 bytes
    /// followed by a single NUL terminator.
    static func encodeStdin(paths: [String]) -> Data {
        var data = Data()
        for path in paths {
            data.append(contentsOf: path.utf8)
            data.append(0)
        }
        return data
    }

    /// Parse `git check-attr -z --stdin filter` output. Format is
    /// `<path>\0filter\0<value>\0` per record, repeated. Tolerant of
    /// trailing partial fragments (returns whatever full records it
    /// can parse).
    static func parse(_ data: Data) -> [LFSCheckAttrResult] {
        // Split on NUL. Trailing empty element after the final NUL
        // is dropped by `omittingEmptySubsequences: true`.
        let tokens = data
            .split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { String(data: Data($0), encoding: .utf8) }

        var results: [LFSCheckAttrResult] = []
        var index = 0
        while index + 2 < tokens.count {
            // Token i = path, i+1 = "filter" (the attribute we asked
            // about), i+2 = value. Verify the attribute name matches
            // what we asked for so we don't silently misalign on a
            // malformed stream.
            let path = tokens[index]
            let attribute = tokens[index + 1]
            let value = tokens[index + 2]
            if attribute == "filter" {
                results.append(LFSCheckAttrResult(path: path, filter: value))
            }
            index += 3
        }
        // tokens.count - index can be 0, 1, or 2 — a partial trailing
        // record is dropped. Real git output never produces partial
        // records, but defensive against truncation.
        return results
    }
}
