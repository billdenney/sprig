// DiffNumstat.swift
//
// ADR 0086 C0 — per-file diff summary from `git diff --numstat -z`: the
// added/deleted line counts and git's own binary marker (the `-`/`-`
// rows). The binary marker is the first, cheapest leg of diff
// classification — git already decided "this file is binary" (NUL byte
// or a `.gitattributes` `binary` attribute), so we don't have to.
//
// `-z` is load-bearing: it NUL-terminates records and emits raw,
// unquoted paths (no C-quoting of non-ASCII names), and gives renames a
// clean three-token shape — `<added>\t<deleted>\t` then the old path
// then the new path, each NUL-separated.
//
// Tier 1, portable. All git access via ``Runner``.

import Foundation

/// One file's numstat row.
public struct NumstatEntry: Sendable, Equatable {
    /// The file's path (the new name for a rename).
    public let path: String
    /// The pre-rename path, when this row is a rename; nil otherwise.
    public let oldPath: String?
    /// Added lines, or nil when git marked the file binary (`-`).
    public let added: Int?
    /// Deleted lines, or nil when git marked the file binary (`-`).
    public let deleted: Int?

    public init(path: String, oldPath: String?, added: Int?, deleted: Int?) {
        self.path = path
        self.oldPath = oldPath
        self.added = added
        self.deleted = deleted
    }

    /// True when git reported this file as binary (both counts `-`).
    public var isBinary: Bool {
        added == nil && deleted == nil
    }
}

/// `git diff --numstat -z` runner + parser.
public enum DiffNumstat {
    /// Run `<baseArguments> --numstat -z` and parse the per-file rows.
    /// `baseArguments` is the diff invocation prefix, e.g. `["diff"]`,
    /// `["diff", "--cached"]`, or `["show", "--format=", sha]`.
    public static func entries(
        runner: Runner,
        baseArguments: [String]
    ) async throws -> [NumstatEntry] {
        let output = try await runner.run(baseArguments + ["--numstat", "-z"])
        return parse(output.stdout)
    }

    /// Parse a `--numstat -z` byte stream. Each normal record is
    /// `<added>\t<deleted>\t<path>`; a rename is `<added>\t<deleted>\t`
    /// (empty path) followed by two more NUL tokens (old, new).
    static func parse(_ data: Data) -> [NumstatEntry] {
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        let tokens = text.components(separatedBy: "\u{0}")
        var entries: [NumstatEntry] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token.isEmpty { continue }
            // A normal record is `<added>\t<deleted>\t<path>` — and `-z`
            // emits raw, UNQUOTED paths, so the path may itself contain a
            // TAB. Cap the split at two so everything after the second
            // TAB stays in the path field (a whole-token split would drop
            // tabbed-path files silently).
            let fields = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 3 else { continue }
            let added = parseCount(fields[0])
            let deleted = parseCount(fields[1])
            if fields[2].isEmpty {
                // Rename: the next two tokens are old path, then new path.
                guard index + 1 < tokens.count else { break }
                let oldPath = tokens[index]
                let newPath = tokens[index + 1]
                index += 2
                entries.append(NumstatEntry(path: newPath, oldPath: oldPath, added: added, deleted: deleted))
            } else {
                entries.append(NumstatEntry(path: fields[2], oldPath: nil, added: added, deleted: deleted))
            }
        }
        return entries
    }

    /// `-` (git's binary marker) → nil; a number → its value.
    private static func parseCount(_ field: String) -> Int? {
        field == "-" ? nil : Int(field)
    }
}
