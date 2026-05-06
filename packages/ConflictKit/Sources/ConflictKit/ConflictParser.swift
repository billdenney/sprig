// ConflictParser.swift
//
// Parser for git's standard conflict-marker format. Recognizes both
// the classic 2-way layout:
//
//     <<<<<<< HEAD
//     ours
//     =======
//     theirs
//     >>>>>>> branch
//
// and the diff3 layout (`merge.conflictstyle = diff3` or `zdiff3`):
//
//     <<<<<<< HEAD
//     ours
//     ||||||| base
//     base content
//     =======
//     theirs
//     >>>>>>> branch
//
// Slice C1 of the M4 (MergeConflictResolver) track. Future slices
// add the resolution model (per-region "take ours" / "take theirs" /
// "edit") and the diff/hunk view that drives the GUI merge surface.

import Foundation

/// Stateless parser that turns a file's text into the conflict
/// regions it contains. Pure-Foundation, no git invocation, no
/// platform APIs.
///
/// **Robustness contract.** `parse(_:)` returns whatever it can
/// recognize; malformed regions (e.g. a leading `<<<<<<<` with no
/// matching `=======` or `>>>>>>>`) are silently skipped. The intent
/// is "show me what's there" — the caller (Recover / Merge UI) can
/// surface a clean state if the result is empty, without us having
/// to crash on a half-resolved file.
public enum ConflictParser {
    /// Marker character counts. Git uses exactly seven of each,
    /// followed by a single space and a label (or end-of-line for
    /// the unlabeled `=======`).
    static let oursMarker = "<<<<<<<"
    static let baseMarker = "|||||||"
    static let theirsMarker = "======="
    static let endMarker = ">>>>>>>"

    /// Parse `source` into its conflict regions. Returns `[]` for
    /// clean input.
    public static func parse(_ source: String) -> [ConflictRegion] {
        var lines: [String] = []
        source.enumerateLines { line, _ in lines.append(line) }
        return parseLines(lines)
    }

    /// Same contract as ``parse(_:)`` but takes pre-split lines —
    /// exposed for tests that want to assert exact line-number
    /// behavior without round-tripping through `enumerateLines`.
    static func parseLines(_ lines: [String]) -> [ConflictRegion] {
        var result: [ConflictRegion] = []
        var index = 0
        while index < lines.count {
            // Each loop iteration either consumes one non-marker
            // line (`index += 1`) or attempts to parse a region
            // starting at the current `<<<<<<<` line. `parseRegion`
            // always returns an `advanceTo` index strictly greater
            // than the starting `<<<`'s index, so the outer loop
            // keeps making progress whether the region is well-formed
            // or malformed.
            if matchMarker(lines[index], prefix: oursMarker) != nil {
                let oursIdx = index
                let (region, advanceTo) = parseRegion(lines: lines, oursAt: oursIdx)
                if let region { result.append(region) }
                // Guarantee forward progress even if `parseRegion`
                // somehow returned <= oursIdx (defensive — shouldn't
                // happen given parseRegion's contract).
                index = max(advanceTo, oursIdx + 1)
            } else {
                index += 1
            }
        }
        return result
    }

    /// Try to parse a region whose `<<<<<<<` marker is at
    /// `lines[oursAt]`. Returns `(region, nextIndex)` on success and
    /// `(nil, nextIndex)` on malformed input.
    ///
    /// Malformed cases:
    ///   - EOF before `=======` or `>>>>>>>` → returns `(nil, lines.count)`,
    ///     dropping everything after the bad `<<<`.
    ///   - A nested `<<<<<<<` appears inside the body before either
    ///     `=======` or `>>>>>>>` → abandons the outer region and
    ///     returns `(nil, nestedIndex)`, letting the outer loop pick
    ///     up the nested marker as a fresh region start. Recovers
    ///     well-formed nested regions inside half-resolved files.
    ///
    /// `nextIndex` is always `> oursAt`.
    private static func parseRegion(
        lines: [String],
        oursAt: Int
    ) -> (ConflictRegion?, Int) {
        guard let oursLabel = matchMarker(lines[oursAt], prefix: oursMarker) else {
            return (nil, oursAt + 1)
        }
        let startLine = oursAt + 1 // 1-indexed

        let oursResult = collectOursAndBase(lines: lines, from: oursAt + 1)
        guard case let .success(oursState) = oursResult else {
            return (nil, oursResult.failureIndex(in: lines))
        }

        let theirsResult = collectTheirs(lines: lines, from: oursState.afterTheirsMarker)
        guard case let .success(theirsState) = theirsResult else {
            return (nil, theirsResult.failureIndex(in: lines))
        }

        // 1-indexed inclusive: `afterEndMarker` already points past
        // the `>>>>>>>` line we just consumed, so the closing line
        // is at `afterEndMarker`.
        let region = ConflictRegion(
            oursLabel: oursLabel,
            baseLabel: oursState.baseLabel,
            theirsLabel: theirsState.theirsLabel,
            ours: oursState.ours,
            base: oursState.base,
            theirs: theirsState.theirs,
            lineRange: startLine ... theirsState.afterEndMarker
        )
        return (region, theirsState.afterEndMarker)
    }

    /// Result of collecting one of the region halves. `.success`
    /// carries the parsed state; `.malformed` carries the index where
    /// the outer loop should resume (an EOF index, a nested `<<<`, …).
    enum SectionResult<State> {
        case success(State)
        case malformed(restartAt: Int)

        func failureIndex(in lines: [String]) -> Int {
            switch self {
            case .success: lines.count
            case let .malformed(restartAt): restartAt
            }
        }
    }

    struct OursState {
        let ours: [String]
        let base: [String]?
        let baseLabel: String?
        /// Index of the first "theirs" line — i.e., right after the
        /// `=======` marker.
        let afterTheirsMarker: Int
    }

    struct TheirsState {
        let theirs: [String]
        let theirsLabel: String
        /// Index just past the `>>>>>>>` close marker.
        let afterEndMarker: Int
    }

    /// Walk `lines` from `start` collecting "ours" content until
    /// `=======`, optionally pivoting through a `|||||||` base
    /// section. Bails if a nested `<<<<<<<` appears or EOF arrives
    /// first.
    private static func collectOursAndBase(
        lines: [String], from start: Int
    ) -> SectionResult<OursState> {
        var index = start
        var ours: [String] = []
        while index < lines.count {
            let line = lines[index]
            if matchMarker(line, prefix: oursMarker) != nil {
                return .malformed(restartAt: index)
            }
            if let baseLabel = matchMarker(line, prefix: baseMarker) {
                return collectBase(
                    lines: lines, from: index + 1,
                    ours: ours, baseLabel: baseLabel
                )
            }
            if line == theirsMarker {
                return .success(OursState(
                    ours: ours, base: nil, baseLabel: nil,
                    afterTheirsMarker: index + 1
                ))
            }
            ours.append(line)
            index += 1
        }
        return .malformed(restartAt: lines.count)
    }

    /// Diff3-only continuation of ``collectOursAndBase(lines:from:)``:
    /// from the line after the `|||||||` marker, collect the base
    /// section until `=======`. Same nested-marker and EOF
    /// protections as the ours collection.
    private static func collectBase(
        lines: [String], from start: Int,
        ours: [String], baseLabel: String
    ) -> SectionResult<OursState> {
        var index = start
        var base: [String] = []
        while index < lines.count {
            let line = lines[index]
            if matchMarker(line, prefix: oursMarker) != nil {
                return .malformed(restartAt: index)
            }
            if line == theirsMarker {
                return .success(OursState(
                    ours: ours, base: base, baseLabel: baseLabel,
                    afterTheirsMarker: index + 1
                ))
            }
            base.append(line)
            index += 1
        }
        return .malformed(restartAt: lines.count)
    }

    /// Walk `lines` from `start` collecting "theirs" content until
    /// `>>>>>>>`. Bails on nested `<<<<<<<` or EOF.
    private static func collectTheirs(
        lines: [String], from start: Int
    ) -> SectionResult<TheirsState> {
        var index = start
        var theirs: [String] = []
        while index < lines.count {
            let line = lines[index]
            if matchMarker(line, prefix: oursMarker) != nil {
                return .malformed(restartAt: index)
            }
            if let label = matchMarker(line, prefix: endMarker) {
                return .success(TheirsState(
                    theirs: theirs, theirsLabel: label,
                    afterEndMarker: index + 1
                ))
            }
            theirs.append(line)
            index += 1
        }
        return .malformed(restartAt: lines.count)
    }

    /// Match `<<<<<<<`-style marker lines: the marker itself, then
    /// optionally a single space and a label. Returns the label
    /// (possibly empty) on match, nil otherwise.
    static func matchMarker(_ line: String, prefix: String) -> String? {
        if line == prefix { return "" }
        let withSpace = prefix + " "
        guard line.hasPrefix(withSpace) else { return nil }
        return String(line.dropFirst(withSpace.count))
    }
}
