// ConflictResolution.swift
//
// The user-side decision for one conflict region: take ours, take
// theirs, take the diff3 base, splice in custom replacement lines, or
// leave the region unresolved (markers preserved). The
// MergeConflictResolver task window (M4 — the MVP gate) and the AI
// conflict-suggestion path both produce values of this type; the
// `ConflictedFile.applying(_:)` method consumes them to produce a
// resolved file.

import Foundation

/// One per-region resolution decision.
public enum ConflictResolution: Equatable, Hashable, Sendable {
    /// Replace the region with the "ours" lines (between
    /// `<<<<<<<` and `=======` / `|||||||`).
    case ours

    /// Replace the region with the "theirs" lines (between
    /// `=======` and `>>>>>>>`).
    case theirs

    /// Replace the region with the diff3 "base" lines. Only valid for
    /// regions parsed from diff3-style markers (i.e. where
    /// ``ConflictRegion/base`` is non-nil); ``ConflictedFile/applying(_:)``
    /// throws ``ConflictResolutionError/baseRequestedButMissing(regionIndex:)``
    /// otherwise.
    case base

    /// Replace the region with arbitrary user-supplied lines. Each
    /// element is one line, no trailing newlines. The empty array
    /// drops the region from the output entirely.
    case custom([String])

    /// Leave the region's marker block in place verbatim — a
    /// pass-through. Useful for partial-resolve workflows where the
    /// user has only decided some regions and wants to keep the rest
    /// for a follow-up pass.
    case unresolved
}

/// Errors thrown by ``ConflictedFile/applying(_:)``.
public enum ConflictResolutionError: Error, Equatable, Sendable {
    /// The number of resolutions handed in didn't match the number of
    /// regions on the file.
    case resolutionCountMismatch(expected: Int, got: Int)

    /// `.base` was requested for a region whose markers don't carry a
    /// base section (i.e. classic 2-way conflict, not diff3).
    /// `regionIndex` is the offending region's position in the
    /// `regions` array.
    case baseRequestedButMissing(regionIndex: Int)
}
