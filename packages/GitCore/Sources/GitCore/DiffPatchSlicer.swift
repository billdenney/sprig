// DiffPatchSlicer.swift
//
// ADR 0061 — region staging's algorithmic core. Given a unified `git
// diff` and a character-range selection into it, emit a patch that —
// fed to `git apply --cached --recount` — stages exactly the selected
// +/- lines. Magit-parity sub-hunk / line / region staging.
//
// The transform is per-line and structure-respecting:
//   - context line  → kept as context (always present, never "staged").
//   - selected `+`  → kept (that line is added to the index).
//   - unselected `+`→ dropped (not added).
//   - selected `-`  → kept (that line is removed from the index).
//   - unselected `-`→ converted to context (the removal is NOT staged).
//   - `\ No newline` → follows its preceding line's fate.
// Each file's header block (`diff --git` … `---`/`+++`, incl. new-file /
// deleted-file / rename / mode headers) is carried through verbatim, so
// non-modification file changes stage correctly; only hunk bodies are
// rewritten and the `@@` counts re-derived (`--recount` is the safety net).
//
// Selecting any part of a `+`/`-` line selects the whole line — you
// can't half-add. A selection touching no change throws.
//
// Tier 1, pure. No git, no I/O. The apply (`git apply --cached
// --recount -`) is the caller's one-liner.

import Foundation

/// Errors from ``DiffPatchSlicer``.
public enum DiffPatchSlicerError: Error, Equatable, Sendable {
    /// The selection intersects no added/removed line — nothing to stage.
    case noChangeSelected
    /// The selection would split a change to a file's last line when that
    /// file has no trailing newline — unrepresentable as a partial patch
    /// (the `\ No newline at end of file` state can't be both kept and
    /// changed). The caller should stage the whole end-of-file change.
    case cannotSplitEndOfFileChange
}

/// A patch staging exactly a selection, plus a summary for the UI.
public struct SlicedPatch: Sendable, Equatable {
    /// Feed to `git apply --cached --recount -`.
    public let patch: String
    /// Selected `+` lines (for the "N added" affordance / a11y).
    public let addedLines: Int
    /// Selected `-` lines.
    public let removedLines: Int
    /// Paths with a surviving change (new-name side; old-name for deletes).
    public let files: [String]

    public init(patch: String, addedLines: Int, removedLines: Int, files: [String]) {
        self.patch = patch
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.files = files
    }
}

/// Slices a unified diff to a patch staging just a selection (ADR 0061).
public enum DiffPatchSlicer {
    /// Slice `diff` (unified `git diff` output) to the patch that stages
    /// exactly the +/- lines intersected by `selection`.
    /// - Throws: ``DiffPatchSlicerError/noChangeSelected`` when the
    ///   selection contains no added/removed line.
    public static func slice(diff: String, selection: Range<String.Index>) throws -> SlicedPatch {
        var patch = ""
        var added = 0
        var removed = 0
        var files: [String] = []
        for section in parseSections(splitLines(diff)) {
            guard let sliced = try sliceSection(section, selection: selection) else { continue }
            patch += sliced.text
            added += sliced.added
            removed += sliced.removed
            if let path = section.newPath ?? section.oldPath { files.append(path) }
        }
        guard !patch.isEmpty else { throw DiffPatchSlicerError.noChangeSelected }
        return SlicedPatch(patch: patch, addedLines: added, removedLines: removed, files: files)
    }

    /// ADR 0061's documented convenience: just the patch string.
    public static func patch(from diff: String, selection: Range<String.Index>) throws -> String {
        try slice(diff: diff, selection: selection).patch
    }

    // MARK: - Model

    private struct Section {
        var header: [Substring] = []
        var hunks: [Hunk] = []
        var oldPath: String?
        var newPath: String?
    }

    private struct Hunk {
        var oldStart: Int
        var newStart: Int
        /// Text after the closing `@@` (function context), incl. newline.
        var trailing: String
        var body: [(text: Substring, range: Range<String.Index>)] = []
    }

    private struct SlicedHunk {
        let lines: [String]
        let added: Int
        let removed: Int
        let oldCount: Int
        let newCount: Int
    }

    private struct SlicedSection {
        let text: String
        let added: Int
        let removed: Int
    }

    // MARK: - Parsing

    /// Split into lines, each carrying its range and its terminator
    /// (so CRLF and a missing final newline are preserved byte-exactly).
    ///
    /// Iterates over Unicode *scalars*, not Characters: Swift folds `\r\n`
    /// into one grapheme cluster, so a Character-level `== "\n"` scan never
    /// fires at a CRLF boundary and would treat the whole diff as one line.
    /// Splitting at the `\n` scalar keeps the preceding `\r` on its line.
    private static func splitLines(_ string: String) -> [(text: Substring, range: Range<String.Index>)] {
        var lines: [(Substring, Range<String.Index>)] = []
        var start = string.startIndex
        let scalars = string.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if scalars[index] == "\n" {
                let next = scalars.index(after: index)
                lines.append((string[start ..< next], start ..< next))
                start = next
            }
            index = scalars.index(after: index)
        }
        if start < string.endIndex { lines.append((string[start...], start ..< string.endIndex)) }
        return lines
    }

    private static func parseSections(_ lines: [(text: Substring, range: Range<String.Index>)]) -> [Section] {
        var sections: [Section] = []
        var section: Section?
        var hunk: Hunk?
        func flushHunk() {
            if let hunk { section?.hunks.append(hunk) }
            hunk = nil
        }
        func flushSection() {
            flushHunk()
            if let section { sections.append(section) }
            section = nil
        }
        for (text, range) in lines {
            if text.hasPrefix("diff --git ") {
                flushSection()
                section = Section(header: [text])
            } else if text.hasPrefix("@@") {
                flushHunk()
                if section == nil { section = Section() }
                hunk = makeHunk(header: text)
            } else if hunk != nil {
                hunk?.body.append((text, range))
            } else {
                if section == nil { section = Section() }
                section?.header.append(text)
                if text.hasPrefix("--- ") {
                    section?.oldPath = headerPath(text)
                } else if text.hasPrefix("+++ ") {
                    section?.newPath = headerPath(text)
                }
            }
        }
        flushSection()
        return sections
    }

    /// Parse `@@ -a,b +c,d @@ trailing` → starts + the verbatim trailing.
    private static func makeHunk(header: Substring) -> Hunk {
        let parts = header.components(separatedBy: "@@")
        let spec = parts.count > 1 ? parts[1] : ""
        let trailing = parts.count > 2 ? parts[2...].joined(separator: "@@") : "\n"
        let tokens = spec.split(separator: " ", omittingEmptySubsequences: true)
        let oldStart = tokens.count > 0 ? Int(tokens[0].dropFirst().split(separator: ",")[0]) ?? 0 : 0
        let newStart = tokens.count > 1 ? Int(tokens[1].dropFirst().split(separator: ",")[0]) ?? 0 : 0
        return Hunk(oldStart: oldStart, newStart: newStart, trailing: trailing)
    }

    private static func headerPath(_ line: Substring) -> String? {
        var path = String(line.dropFirst(4)).trimmingCharacters(in: .newlines)
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        return path.isEmpty ? nil : path
    }

    // MARK: - Slicing

    private static func sliceSection(
        _ section: Section, selection: Range<String.Index>
    ) throws -> SlicedSection? {
        var hunkTexts: [String] = []
        var added = 0
        var removed = 0
        for hunk in section.hunks {
            guard let sliced = try sliceHunk(hunk, selection: selection) else { continue }
            let header = "@@ -\(hunk.oldStart),\(sliced.oldCount) +\(hunk.newStart),\(sliced.newCount) @@"
            hunkTexts.append(header + hunk.trailing + sliced.lines.joined())
            added += sliced.added
            removed += sliced.removed
        }
        guard !hunkTexts.isEmpty else { return nil }
        let text = section.header.map(String.init).joined() + hunkTexts.joined()
        return SlicedSection(text: text, added: added, removed: removed)
    }

    private static func sliceHunk(_ hunk: Hunk, selection: Range<String.Index>) throws -> SlicedHunk? {
        var lines: [String] = []
        var added = 0, removed = 0, oldCount = 0, newCount = 0
        var lastKept = false
        for (text, range) in hunk.body {
            switch text.first {
            case " ", "\t":
                lines.append(String(text)); oldCount += 1; newCount += 1; lastKept = true
            case "+":
                if intersects(range, selection) {
                    lines.append(String(text)); added += 1; newCount += 1; lastKept = true
                } else { lastKept = false }
            case "-":
                if intersects(range, selection) {
                    lines.append(String(text)); removed += 1; oldCount += 1; lastKept = true
                } else {
                    lines.append(" " + text.dropFirst()); oldCount += 1; newCount += 1; lastKept = true
                }
            case "\\":
                if lastKept { lines.append(String(text)) }
            default:
                lines.append(String(text)); lastKept = true
            }
        }
        guard added > 0 || removed > 0 else { return nil }
        try validateNoNewlineMarkers(lines)
        return SlicedHunk(lines: lines, added: added, removed: removed, oldCount: oldCount, newCount: newCount)
    }

    /// A `\ No newline at end of file` marker is valid only at the new
    /// EOF: terminal, or trailing a `-` line (an old-EOF marker before the
    /// paired `+`). A marker trailing a non-terminal context line means an
    /// unselected `-`→context demotion stranded the EOF state — that split
    /// is unrepresentable (it would silently mis-stage), so refuse it.
    private static func validateNoNewlineMarkers(_ lines: [String]) throws {
        for (index, line) in lines.enumerated() where line.first == "\\" {
            let isTerminal = index == lines.count - 1
            let trailsRemoval = index > 0 && lines[index - 1].first == "-"
            if !isTerminal, !trailsRemoval {
                throw DiffPatchSlicerError.cannotSplitEndOfFileChange
            }
        }
    }

    private static func intersects(_ line: Range<String.Index>, _ selection: Range<String.Index>) -> Bool {
        if selection.isEmpty { return line.contains(selection.lowerBound) }
        return selection.lowerBound < line.upperBound && line.lowerBound < selection.upperBound
    }
}
