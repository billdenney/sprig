// ConflictRegion.swift
//
// One contiguous block of conflict markers in a working-tree file
// after a failed `git merge` / `rebase` / `cherry-pick`. The
// `ConflictParser` turns a file's raw contents into an array of
// these.
//
// Wire-stable: the macOS / Windows MergeConflictResolver task window
// (M4 — the MVP gate) and the AI conflict-suggestion path both
// consume `[ConflictRegion]`, so the field shape is part of the
// engine's public surface.

import Foundation

/// One conflict region between a pair of `<<<<<<<` / `>>>>>>>`
/// markers (with optional `|||||||` "base" section in diff3 / zdiff3
/// modes).
///
/// Lines are stored without trailing newlines — `ConflictParser` uses
/// `String.enumerateLines(invoking:)` so CRLF input is normalized to
/// LF-relative line slices on every platform.
public struct ConflictRegion: Equatable, Hashable, Sendable {
    /// Label after the `<<<<<<<` marker — typically `HEAD` for a
    /// `git merge`, or a commit subject for a `git rebase` /
    /// `cherry-pick`. Empty if the marker has no label (rare; git
    /// always writes one in practice).
    public let oursLabel: String

    /// Label after the `|||||||` marker, when diff3-style markers are
    /// in use (`merge.conflictstyle = diff3` or `zdiff3`). Nil for
    /// the classic 2-way style.
    public let baseLabel: String?

    /// Label after the `>>>>>>>` marker — the "incoming" side's
    /// identifier (branch name, commit subject, …).
    public let theirsLabel: String

    /// "Ours" lines — between `<<<<<<<` and `=======` (or `|||||||`).
    public let ours: [String]

    /// "Base" lines — between `|||||||` and `=======`. Nil when the
    /// markers don't include a base section.
    public let base: [String]?

    /// "Theirs" lines — between `=======` and `>>>>>>>`.
    public let theirs: [String]

    /// 1-indexed inclusive line range in the *input* covering the
    /// entire conflict region — the leading `<<<<<<<` line through
    /// the trailing `>>>>>>>` line. The Recover / MergeConflictResolver
    /// UIs use this to splice the chosen resolution back into the
    /// surrounding file.
    public let lineRange: ClosedRange<Int>

    public init(
        oursLabel: String,
        baseLabel: String?,
        theirsLabel: String,
        ours: [String],
        base: [String]?,
        theirs: [String],
        lineRange: ClosedRange<Int>
    ) {
        self.oursLabel = oursLabel
        self.baseLabel = baseLabel
        self.theirsLabel = theirsLabel
        self.ours = ours
        self.base = base
        self.theirs = theirs
        self.lineRange = lineRange
    }
}
