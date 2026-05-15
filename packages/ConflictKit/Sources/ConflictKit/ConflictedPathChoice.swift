// ConflictedPathChoice.swift
//
// What the user has chosen to do with a single conflicted path. Lives
// in ConflictKit alongside ``ConflictKind`` because it's a semantic
// type, not a VM-specific one — the same choice surface is consumed
// by `MergeConflictResolverViewModel` (M4 MVP-gate task window) and
// by `sprigctl conflicts --resolve` (CLI, future).
//
// **Whole-side pick** is the MVP cut. Per-region text resolution
// (using ``ConflictResolution`` per ``ConflictRegion``) is a future
// `.text(regions: [ConflictResolution])` case; deferred so the M4 VM
// can ship the table-stakes "use ours / use theirs" affordance
// without waiting on the diff-rendering selection UX.

import Foundation

/// The user's chosen resolution for one conflicted path. Pairs with
/// a ``ClassifiedConflict`` keyed by path in the M4
/// MergeConflictResolver's state map.
///
/// Whole-side picks (``ours`` / ``theirs`` / ``base``) work for every
/// ``ConflictKind``. ``base`` is only valid when the conflict has a
/// base stage (i.e. ``UnmergedEntry/isAddAdd`` is false); the VM
/// rejects ``base`` for add/add conflicts with a typed error.
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
}

public extension ConflictedPathChoice {
    /// True when this choice is anything other than ``pending``.
    var isResolved: Bool {
        self != .pending
    }

    /// The stage number this choice maps to (1 = base, 2 = ours,
    /// 3 = theirs). `nil` for ``pending``.
    var stage: Int? {
        switch self {
        case .pending: nil
        case .base: 1
        case .ours: 2
        case .theirs: 3
        }
    }
}
