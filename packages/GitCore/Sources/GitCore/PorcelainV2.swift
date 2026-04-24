// PorcelainV2 — typed model of `git status --porcelain=v2 -z` output.
//
// Format reference: git-status(1) "Porcelain Format Version 2".
// With `-z`, records are NUL-terminated and paths are never quoted, which is
// why Sprig always invokes with `-z` and parses bytes directly.

import Foundation

/// The complete parsed result of a `git status --porcelain=v2 -z` call.
public struct PorcelainV2Status: Sendable, Equatable {
    public var branch: BranchInfo?
    public var stashCount: Int?
    public var entries: [Entry]

    public init(
        branch: BranchInfo? = nil,
        stashCount: Int? = nil,
        entries: [Entry] = []
    ) {
        self.branch = branch
        self.stashCount = stashCount
        self.entries = entries
    }
}

/// Branch-level headers (oid, head name, upstream, ahead/behind).
public struct BranchInfo: Sendable, Equatable {
    /// Commit SHA of HEAD, or `nil` when the repo is newly-initialized (`(initial)`).
    public var oid: String?
    /// Current branch name, or `nil` when HEAD is detached (`(detached)`).
    public var head: String?
    /// Upstream tracking ref, e.g. `origin/main`. Nil when none is configured.
    public var upstream: String?
    /// Commits ahead of upstream (nil when no upstream).
    public var ahead: Int?
    /// Commits behind upstream (nil when no upstream).
    public var behind: Int?

    public init(
        oid: String? = nil,
        head: String? = nil,
        upstream: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil
    ) {
        self.oid = oid
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

/// A single entry in porcelain-v2 output.
public enum Entry: Sendable, Equatable {
    case ordinary(Ordinary)
    case renamed(Renamed)
    case unmerged(Unmerged)
    case untracked(path: String)
    case ignored(path: String)

    /// Convenience: the primary path associated with this entry.
    public var path: String {
        switch self {
        case .ordinary(let e): return e.path
        case .renamed(let e): return e.path
        case .unmerged(let e): return e.path
        case .untracked(let path): return path
        case .ignored(let path): return path
        }
    }
}

/// The two-character `<XY>` status code: index state and worktree state.
public struct StatusXY: Sendable, Equatable {
    public var index: StatusCode
    public var worktree: StatusCode
    public init(index: StatusCode, worktree: StatusCode) {
        self.index = index
        self.worktree = worktree
    }
}

/// Single-character status code appearing in `<XY>`.
public enum StatusCode: Character, Sendable, Equatable {
    case unmodified = "."
    case modified = "M"
    case typeChanged = "T"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case updatedUnmerged = "U"
}

/// Submodule state encoded in the `<sub>` field.
///
/// - `N...` when the entry is not a submodule.
/// - `S<c><m><u>` where each flag is uppercase (yes) or lowercase (no).
public struct SubmoduleState: Sendable, Equatable {
    public var isSubmodule: Bool
    public var commitChanged: Bool
    public var trackedModified: Bool
    public var untrackedModified: Bool

    public init(
        isSubmodule: Bool,
        commitChanged: Bool = false,
        trackedModified: Bool = false,
        untrackedModified: Bool = false
    ) {
        self.isSubmodule = isSubmodule
        self.commitChanged = commitChanged
        self.trackedModified = trackedModified
        self.untrackedModified = untrackedModified
    }

    public static let notSubmodule = SubmoduleState(isSubmodule: false)
}

/// An ordinary changed entry (porcelain-v2 line prefix `1 `).
public struct Ordinary: Sendable, Equatable {
    public var xy: StatusXY
    public var submodule: SubmoduleState
    public var modeHead: UInt32
    public var modeIndex: UInt32
    public var modeWorktree: UInt32
    public var hashHead: String
    public var hashIndex: String
    public var path: String

    public init(
        xy: StatusXY,
        submodule: SubmoduleState,
        modeHead: UInt32,
        modeIndex: UInt32,
        modeWorktree: UInt32,
        hashHead: String,
        hashIndex: String,
        path: String
    ) {
        self.xy = xy
        self.submodule = submodule
        self.modeHead = modeHead
        self.modeIndex = modeIndex
        self.modeWorktree = modeWorktree
        self.hashHead = hashHead
        self.hashIndex = hashIndex
        self.path = path
    }
}

/// A renamed or copied entry (prefix `2 `).
public struct Renamed: Sendable, Equatable {
    public var xy: StatusXY
    public var submodule: SubmoduleState
    public var modeHead: UInt32
    public var modeIndex: UInt32
    public var modeWorktree: UInt32
    public var hashHead: String
    public var hashIndex: String
    public var op: RenameOp
    public var score: Int
    public var path: String
    public var origPath: String

    public init(
        xy: StatusXY,
        submodule: SubmoduleState,
        modeHead: UInt32,
        modeIndex: UInt32,
        modeWorktree: UInt32,
        hashHead: String,
        hashIndex: String,
        op: RenameOp,
        score: Int,
        path: String,
        origPath: String
    ) {
        self.xy = xy
        self.submodule = submodule
        self.modeHead = modeHead
        self.modeIndex = modeIndex
        self.modeWorktree = modeWorktree
        self.hashHead = hashHead
        self.hashIndex = hashIndex
        self.op = op
        self.score = score
        self.path = path
        self.origPath = origPath
    }
}

/// Rename vs. copy marker in a type-2 entry.
public enum RenameOp: Character, Sendable, Equatable {
    case renamed = "R"
    case copied = "C"
}

/// An unmerged (conflicted) entry (prefix `u `).
public struct Unmerged: Sendable, Equatable {
    public var xy: StatusXY
    public var submodule: SubmoduleState
    public var modeStage1: UInt32
    public var modeStage2: UInt32
    public var modeStage3: UInt32
    public var modeWorktree: UInt32
    public var hashStage1: String
    public var hashStage2: String
    public var hashStage3: String
    public var path: String

    public init(
        xy: StatusXY,
        submodule: SubmoduleState,
        modeStage1: UInt32,
        modeStage2: UInt32,
        modeStage3: UInt32,
        modeWorktree: UInt32,
        hashStage1: String,
        hashStage2: String,
        hashStage3: String,
        path: String
    ) {
        self.xy = xy
        self.submodule = submodule
        self.modeStage1 = modeStage1
        self.modeStage2 = modeStage2
        self.modeStage3 = modeStage3
        self.modeWorktree = modeWorktree
        self.hashStage1 = hashStage1
        self.hashStage2 = hashStage2
        self.hashStage3 = hashStage3
        self.path = path
    }
}
