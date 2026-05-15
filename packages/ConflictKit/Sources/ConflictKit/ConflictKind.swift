// ConflictKind.swift
//
// Classification of conflicted paths from `git ls-files -u -z` into
// the resolution UX affordance the M4 MergeConflictResolver should
// surface. Pairs with `GitCore.UnmergedListing` (which parses the
// raw stage data) and the existing `ConflictParser` (which handles
// text-marker regions within a single file).
//
// Tier 1 portable. The classifier is a pure function over an
// ``UnmergedEntry`` (and, for the LFS / binary cases, an optional
// content / attribute probe the caller supplies). No I/O, no git
// invocation here.
//
// The five kinds:
//
//   - .text             — both sides have file content; the
//                          MergeConflictResolver renders
//                          `<<<<<<<` markers and uses
//                          ``ConflictParser`` to split into
//                          ``ConflictRegion``s. Default classification.
//   - .binary           — at least one stage is a binary blob; no
//                          line-level merge is possible. UI offers
//                          "use ours" / "use theirs" / abort.
//   - .lfsPointer       — the file is LFS-tracked (per
//                          .gitattributes); resolution picks a
//                          pointer to keep, the agent runs
//                          `git lfs fetch / checkout` for it.
//   - .submodule        — at least one stage is mode 160000
//                          (gitlink). UI offers pick-a-commit
//                          affordance for the submodule's SHA.
//   - .addAdd           — no common ancestor (stage 1 absent). UI
//                          offers "keep ours" / "keep theirs" /
//                          rename-one-side affordance.
//
// Classification rules — applied in order, first match wins:
//
//   1. If any stage's mode is 160000 (submodule) → .submodule
//   2. If the caller indicates the path is LFS-tracked → .lfsPointer
//      (this overrides the binary heuristic — LFS pointers are
//      tiny text files; they're "binary" semantically but their
//      resolution UX is LFS-specific)
//   3. If the caller indicates the path is binary → .binary
//   4. If stage 1 is absent → .addAdd
//   5. Otherwise → .text

import Foundation
import GitCore

/// The kind of conflict at a single unmerged path. Drives the M4
/// MergeConflictResolver's per-path UI affordance.
public enum ConflictKind: Sendable, Equatable, Hashable, CaseIterable {
    /// Both sides have line-mergeable text content. The
    /// MergeConflictResolver renders conflict markers and uses
    /// ``ConflictParser`` to split into ``ConflictRegion``s.
    case text

    /// Binary file (per `.gitattributes` `binary` attribute or
    /// caller's content sniff). No line-level merge possible; UI
    /// offers ours / theirs / abort.
    case binary

    /// LFS pointer file (per `.gitattributes` `filter=lfs`).
    /// Resolution picks a pointer; the agent runs `git lfs fetch +
    /// checkout` for the chosen side.
    case lfsPointer

    /// Submodule pointer conflict (at least one stage has mode
    /// 160000). Resolution picks which submodule commit SHA wins.
    case submodule

    /// Both sides added the path with no common ancestor (stage 1
    /// absent). Resolution picks one side, or renames one.
    case addAdd
}

/// Probes the caller supplies for kinds the parser can't infer from
/// `UnmergedEntry` alone (binary detection needs content peek;
/// LFS-pointer detection needs `.gitattributes`).
///
/// Both probes are sync, so the classifier itself stays sync.
/// Callers that need to consult LFSKit's async APIs probe ahead of
/// time and pass the result via closures here.
public struct ConflictProbes: Sendable {
    /// Returns `true` if the path is LFS-tracked. Typically wired to
    /// `LFSKit.LFSAttributeChecker`. If `nil`, LFS classification is
    /// skipped (the path falls through to `.binary` / `.text`).
    public let isLFSTracked: (@Sendable (_ path: String) -> Bool)?

    /// Returns `true` if the path is binary (e.g. content sniff or
    /// `.gitattributes` `binary` attribute). If `nil`, binary
    /// classification is skipped — the path falls through to
    /// `.text` / `.addAdd`.
    public let isBinary: (@Sendable (_ path: String) -> Bool)?

    public init(
        isLFSTracked: (@Sendable (_ path: String) -> Bool)? = nil,
        isBinary: (@Sendable (_ path: String) -> Bool)? = nil
    ) {
        self.isLFSTracked = isLFSTracked
        self.isBinary = isBinary
    }

    /// No probes — submodule + add-add classification only; every
    /// other case falls back to `.text`. Useful when the caller
    /// hasn't wired LFS / binary detection yet.
    public static let none = ConflictProbes()
}

public extension ConflictKind {
    /// Classify an unmerged entry into the right conflict kind.
    /// Rules in the file header. Defaults to `.text` when no probe
    /// matches and the entry doesn't show submodule / add-add
    /// shapes.
    static func classify(
        _ entry: UnmergedEntry,
        probes: ConflictProbes = .none
    ) -> ConflictKind {
        // 1. Submodule shape from the stage mode (no probe needed).
        if entry.hasSubmoduleStage { return .submodule }

        // 2. LFS pointer takes precedence over binary because LFS
        //    pointers are technically text, but their UX flow is
        //    LFS-specific (fetch / checkout for the chosen side).
        if let isLFS = probes.isLFSTracked, isLFS(entry.path) {
            return .lfsPointer
        }

        // 3. Binary per caller's probe.
        if let isBin = probes.isBinary, isBin(entry.path) {
            return .binary
        }

        // 4. Add/add shape from the stage set (no probe needed).
        if entry.isAddAdd { return .addAdd }

        // 5. Default — line-mergeable text.
        return .text
    }
}

/// A conflicted path with its classified kind. The M4
/// MergeConflictResolver renders one list row per ``ClassifiedConflict``
/// and routes the click to the per-kind UI affordance.
public struct ClassifiedConflict: Sendable, Equatable {
    public let entry: UnmergedEntry
    public let kind: ConflictKind

    public init(entry: UnmergedEntry, kind: ConflictKind) {
        self.entry = entry
        self.kind = kind
    }
}

public extension ConflictKind {
    /// Bulk-classify every entry in `entries`. Convenience over
    /// ``classify(_:probes:)`` for the typical
    /// "feed the whole `UnmergedListing.parse` output through" flow.
    static func classifyAll(
        _ entries: [UnmergedEntry],
        probes: ConflictProbes = .none
    ) -> [ClassifiedConflict] {
        entries.map { entry in
            ClassifiedConflict(entry: entry, kind: classify(entry, probes: probes))
        }
    }
}
