// ConflictedPathChoice.swift
//
// What the user has chosen to do with a single conflicted path. Lives
// in ConflictKit alongside ``ConflictKind`` because it's a semantic
// type, not a VM-specific one — the same choice surface is consumed
// by `MergeConflictResolverViewModel` (M4 MVP-gate task window) and
// by `sprigctl conflicts --resolve` (CLI, future).
//
// Two granularities:
//   - Whole-side: ``ours`` / ``theirs`` / ``base`` — works for every
//     ``ConflictKind``, including binary / submodule / add-add.
//   - Per-region: ``text(regions:)`` — line-mergeable text conflicts
//     where the user picks ours/theirs/base/custom per
//     ``ConflictRegion``. Only meaningful for ``ConflictKind/text``;
//     the VM rejects this choice for other kinds at apply time.

import Foundation

/// The user's chosen resolution for one conflicted path. Pairs with
/// a ``ClassifiedConflict`` keyed by path in the M4
/// MergeConflictResolver's state map.
///
/// Whole-side picks (``ours`` / ``theirs`` / ``base``) work for every
/// ``ConflictKind``. ``base`` is only valid when the conflict has a
/// base stage (i.e. ``UnmergedEntry/isAddAdd`` is false); the VM
/// rejects ``base`` for add/add conflicts with a typed error.
///
/// The ``text(regions:)`` case is only meaningful for
/// ``ConflictKind/text``-classified paths and lets the user choose a
/// resolution per ``ConflictRegion`` (the typical "accept ours here,
/// theirs there" workflow). The VM hands the regions array to
/// ``ConflictedFile/applying(_:)`` for the splice.
public enum ConflictedPathChoice: Sendable, Equatable, Hashable {
    /// No choice yet. UI shows the path as "unresolved"; the VM's
    /// "apply" actions skip it; ``finalize`` is blocked while any
    /// path is `.pending`.
    case pending

    /// Use the "ours" / HEAD side wholesale. For text conflicts that
    /// means HEAD's full file content; for binary, submodule, and
    /// add-add it's the same.
    case ours

    /// Use the "theirs" / incoming side wholesale.
    case theirs

    /// Use the "base" / common-ancestor side wholesale. Only valid
    /// for conflicts that have a base stage; rejected at apply time
    /// for add/add conflicts.
    case base

    /// Per-``ConflictRegion`` resolution for a text conflict. The
    /// array's length must equal the number of regions the file's
    /// ``ConflictedFile`` parses (``ConflictedFile/regions``); the
    /// VM's apply path validates this and rejects mismatches with
    /// ``ConflictResolutionError/resolutionCountMismatch(expected:got:)``.
    ///
    /// Only valid for ``ConflictKind/text``-classified paths. The
    /// VM rejects this choice on other kinds with a clear failure
    /// description.
    case text(regions: [ConflictResolution])
}

public extension ConflictedPathChoice {
    /// True when this choice is anything other than ``pending``.
    var isResolved: Bool {
        self != .pending
    }

    /// The stage number this choice maps to for whole-side picks
    /// (1 = base, 2 = ours, 3 = theirs). `nil` for ``pending`` and
    /// for ``text(regions:)`` (which doesn't map to a single stage —
    /// it splices per-region from `ours` / `theirs` / `base` / custom
    /// inside ``ConflictedFile/applying(_:)``).
    var stage: Int? {
        switch self {
        case .pending, .text: nil
        case .base: 1
        case .ours: 2
        case .theirs: 3
        }
    }
}
