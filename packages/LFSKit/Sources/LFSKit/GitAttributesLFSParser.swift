// GitAttributesLFSParser.swift
//
// Extracts LFS-tracked path patterns from a `.gitattributes` file.
// Per the git-lfs convention, `filter=lfs diff=lfs merge=lfs -text`
// applied to a path pattern declares those paths as LFS-tracked. Only
// the `filter=lfs` attribute is required for LFS treatment; the
// `diff` / `merge` / `-text` attributes commonly accompany it but
// don't affect filter routing.
//
// This parser is **focused on LFS** — it ignores any line that doesn't
// declare `filter=lfs`, and doesn't try to be a general
// `.gitattributes` parser. Sprig's broader attribute support (text /
// binary / language detection) lands in `GitCore` if/when it becomes
// load-bearing; for the `.lfsPointer` badge path, "is this path
// LFS-tracked?" is the only question we ask.
//
// Tier 1, Foundation-only.

import Foundation

/// One `.gitattributes` rule that marks a path pattern as LFS-tracked.
public struct LFSAttributeRule: Equatable, Hashable, Sendable {
    /// The path pattern verbatim — gitignore-style globbing per the
    /// `gitattributes(5)` man page (e.g. `*.psd`, `images/*.png`,
    /// `binary/**`). Pattern matching is intentionally **not** in
    /// this slice; future work either calls `git check-attr` (the
    /// authoritative answer for any path) or implements a pure-Swift
    /// fnmatch in a follow-up.
    public let pattern: String

    /// 1-indexed line number of the rule in the source file.
    /// Surfaced so diagnostics ("conflicting LFS rules at line N and
    /// line M") can point precisely.
    public let lineNumber: Int

    public init(pattern: String, lineNumber: Int) {
        self.pattern = pattern
        self.lineNumber = lineNumber
    }
}

/// Extracts LFS-tracked rules from a `.gitattributes` file's contents.
public enum GitAttributesLFSParser {
    /// Parse `source` and return one ``LFSAttributeRule`` per line
    /// that declares `filter=lfs`.
    ///
    /// Lines that are blank, start with `#` (comments), or don't
    /// include `filter=lfs` are silently skipped — this is an
    /// extraction, not a validation pass.
    ///
    /// CRLF input is normalized via `enumerateLines`. The pattern
    /// preserves quoted-path escaping (e.g. `"file with spaces.psd"`)
    /// verbatim — the consumer handles unquoting if needed for
    /// matching.
    public static func extractLFSRules(_ source: String) -> [LFSAttributeRule] {
        var result: [LFSAttributeRule] = []
        var lineNumber = 0
        source.enumerateLines { line, _ in
            lineNumber += 1
            if let rule = parseLine(line, lineNumber: lineNumber) {
                result.append(rule)
            }
        }
        return result
    }

    /// Parse one line. Exposed for tests and for callers that read
    /// `.gitattributes` line-by-line (e.g. streaming a huge file).
    static func parseLine(_ line: String, lineNumber: Int) -> LFSAttributeRule? {
        // Trim leading whitespace; preserve internal layout for
        // pattern + attrs.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("#") else { return nil }

        // Tokenize on runs of horizontal whitespace, but respect
        // quoting around the path pattern. Quoted paths can contain
        // spaces; everything after the first whitespace boundary
        // outside the quotes is attributes.
        guard let (pattern, attributesText) = splitPatternAndAttributes(trimmed) else {
            return nil
        }
        guard hasLFSFilter(in: attributesText) else { return nil }
        return LFSAttributeRule(pattern: pattern, lineNumber: lineNumber)
    }

    /// Split a trimmed `.gitattributes` line into `(pattern,
    /// attributes)` at the first whitespace boundary outside of any
    /// double-quoted region. Returns nil if there's no attribute
    /// portion at all (a pattern with no attributes is not an LFS
    /// rule).
    static func splitPatternAndAttributes(_ line: String) -> (String, String)? {
        var inQuotes = false
        var splitIndex: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, char == " " || char == "\t" {
                splitIndex = index
                break
            }
            index = line.index(after: index)
        }
        guard let split = splitIndex else { return nil }
        let pattern = String(line[..<split])
        let attrs = String(line[split...]).trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !attrs.isEmpty else { return nil }
        return (pattern, attrs)
    }

    /// True iff `attributes` contains a `filter=lfs` declaration as a
    /// whitespace-bounded token. Avoids false positives like a
    /// pattern named `filter=lfs.txt` or a longer attribute name
    /// that happens to start with `filter=lfs` (none exist today,
    /// but defensive).
    static func hasLFSFilter(in attributes: String) -> Bool {
        // Tokenize on whitespace; check for an exact `filter=lfs`
        // token. `gitattributes(5)` allows attribute values with `=`
        // (e.g. `eol=lf`) but `filter=lfs` is the single canonical
        // form — git-lfs tooling always writes it this way.
        attributes
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .contains("filter=lfs")
    }
}
