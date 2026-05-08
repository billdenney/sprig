// SubmoduleStatusParser — parse `git submodule status` output into
// `[SubmoduleEntry]`.
//
// Tier 1 portable. Pure Foundation; no platform APIs.
//
// `git submodule status [--recursive] [--cached]` emits one line per
// submodule with the format:
//
//     <state-char><sha> <path>[ (refname)]
//
// where `<state-char>` is one of `' '` / `'+'` / `'-'` / `'U'` (per
// `git-submodule(1)`'s "STATUS" section), `<sha>` is the super-repo's
// recorded pointer (40 hex chars for SHA-1, 64 for SHA-256), and the
// optional `(refname)` suffix is the result of `git describe` against
// the submodule's current HEAD (only present when describable —
// initialized, on a ref, not `--cached`).
//
// Crucially, `git submodule status` does NOT honor `-z`, does NOT
// honor `core.quotePath`, and does NOT quote paths. Paths can contain
// spaces. The existing whitespace-split in
// `GitCore.GitMetadataPaths.submoduleWorktrees` reads only the first
// path component for paths-with-spaces; this parser is the
// typed-model upgrade and parses the full path correctly by reading
// from the left (state, SHA) and from the right (`(refname)`), with
// the middle as the path.

import Foundation

/// Parser for `git submodule status` output.
public enum SubmoduleStatusParser {
    /// Parse the raw stdout of `git submodule status [--recursive]
    /// [--cached]` into a list of typed entries, in the order git
    /// emitted them.
    ///
    /// - Throws: ``ParseError`` on the first malformed line.
    public static func parse(_ raw: String) throws -> [SubmoduleEntry] {
        var entries: [SubmoduleEntry] = []
        var caughtError: ParseError?

        // `String.enumerateLines` is CRLF-safe — it handles `\n`, `\r\n`,
        // and bare `\r` consistently across macOS, Linux, and Windows
        // Foundation, where `split(whereSeparator: \.isNewline)` does
        // not (it leaves `\r` attached to the previous line on inputs
        // emitted with bare `\r\n` from a Windows-side git).
        raw.enumerateLines { line, stop in
            do {
                if let entry = try parseLine(line) {
                    entries.append(entry)
                }
            } catch let error as ParseError {
                caughtError = error
                stop = true
            } catch {
                caughtError = .malformedLine(line)
                stop = true
            }
        }

        if let caughtError {
            throw caughtError
        }
        return entries
    }

    /// Parse one line. Returns nil for blank lines (so callers can
    /// tolerate trailing newlines / blank separators); throws on
    /// malformed non-blank lines.
    private static func parseLine(_ line: String) throws -> SubmoduleEntry? {
        let chars = Array(line)
        guard !chars.isEmpty else { return nil }

        // Step 1: state char.
        let state: SubmoduleEntry.State
        switch chars[0] {
        case " ":
            state = .clean
        case "+":
            state = .outOfDate
        case "-":
            state = .notInitialized
        case "U":
            state = .mergeConflict
        default:
            throw ParseError.unknownStateChar(chars[0])
        }

        // Step 2: SHA (run of hex chars from index 1).
        var sha = ""
        var index = 1
        while index < chars.count, isHex(chars[index]) {
            sha.append(chars[index])
            index += 1
        }
        guard sha.count == 40 || sha.count == 64 else {
            throw ParseError.shaUnexpectedShape(sha)
        }

        // Step 3: separator space between SHA and path.
        guard index < chars.count, chars[index] == " " else {
            throw ParseError.malformedLine(line)
        }
        index += 1

        // Step 4: remainder is `<path>[ (refname)]`.
        let remainder = String(chars[index...])
        let (path, refDescription) = try splitPathAndRefDescription(remainder, originalLine: line)

        return SubmoduleEntry(
            state: state,
            recordedSHA: sha,
            path: path,
            refDescription: refDescription
        )
    }

    /// Split the post-SHA remainder of a line into `(path,
    /// refDescription)`.
    ///
    /// The refname suffix, when present, has the shape ` (X)` at the
    /// very end of the line, where `X` is the output of `git
    /// describe` against the submodule's HEAD. Refnames don't contain
    /// `)` or whitespace (per `git-check-ref-format(1)`), so a
    /// trailing `(...)` group whose content contains no whitespace
    /// is overwhelmingly likely to be a refname rather than part of
    /// the path. We use that heuristic to tell them apart.
    ///
    /// Acceptable known limitation: if a submodule's path literally
    /// ends with ` (no-spaces-here)` and the line has no real
    /// refname (uninitialized, `--cached`, or detached non-describable
    /// HEAD), the heuristic misattributes the path's trailing
    /// paren-group as a refname. Submodule paths ending in `)` are
    /// vanishingly rare; users hitting this case can pass `--cached`
    /// to remove the ambiguity (no refname is ever appended in
    /// `--cached` mode, but the trailing-paren heuristic still
    /// triggers, so this isn't a complete escape — it remains a
    /// genuine output-format ambiguity in `git submodule status`).
    private static func splitPathAndRefDescription(
        _ remainder: String,
        originalLine: String
    ) throws -> (path: String, refDescription: String?) {
        // Reject embedded newlines — `git submodule status` doesn't
        // support `-z`, so paths containing `\n` (or bare `\r`) can't
        // be reliably parsed from this output. Surface the limitation
        // rather than silently truncate. (`enumerateLines` strips line
        // terminators, so a single embedded newline within a quoted
        // path would have already split the entry across two
        // "lines" — this check is a defense-in-depth sanity net.)
        if remainder.contains("\n") || remainder.contains("\r") {
            throw ParseError.pathContainsNewline(line: originalLine)
        }

        let (path, refDescription) = extractTrailingRefname(from: remainder)
        if path.isEmpty {
            throw ParseError.malformedLine(originalLine)
        }
        return (path, refDescription)
    }

    /// Detect a trailing ` (refname)` suffix on `remainder`. Anchor
    /// on the last ` (` in the string: the substring between that
    /// `(` and the closing `)` is a refname candidate. Treat it as a
    /// real refname only when non-empty and whitespace-free, matching
    /// `git-check-ref-format(1)` rules.
    private static func extractTrailingRefname(from remainder: String) -> (path: String, refDescription: String?) {
        guard remainder.hasSuffix(")"),
              let openRange = remainder.range(of: " (", options: .backwards)
        else {
            return (remainder, nil)
        }
        let closeIndex = remainder.index(before: remainder.endIndex)
        let refContentStart = openRange.upperBound
        guard refContentStart < closeIndex else {
            return (remainder, nil)
        }
        let candidate = remainder[refContentStart ..< closeIndex]
        guard !candidate.isEmpty, !candidate.contains(where: \.isWhitespace) else {
            return (remainder, nil)
        }
        return (String(remainder[..<openRange.lowerBound]), String(candidate))
    }

    private static func isHex(_ char: Character) -> Bool {
        switch char {
        case "0" ... "9", "a" ... "f", "A" ... "F":
            true
        default:
            false
        }
    }

    /// Failures parsing a line of `git submodule status` output.
    public enum ParseError: Error, Equatable {
        /// Line's overall structure didn't match `<state><sha>
        /// <path>[ (refname)]`. Carries the raw offending line.
        case malformedLine(String)
        /// First character wasn't one of `' '` / `'+'` / `'-'` /
        /// `'U'`.
        case unknownStateChar(Character)
        /// Hex run after the state char had a length other than 40
        /// (SHA-1) or 64 (SHA-256). Carries the consumed hex.
        case shaUnexpectedShape(String)
        /// Path contained a newline, which `git submodule status`
        /// can't disambiguate (no `-z` support). Carries the raw
        /// offending line for diagnostics.
        case pathContainsNewline(line: String)
    }
}
