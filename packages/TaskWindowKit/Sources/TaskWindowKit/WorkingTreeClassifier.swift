// WorkingTreeClassifier.swift
//
// The one porcelain-v2-entry → bucket classification, shared by the
// CommitComposer (which needs the PATHS per bucket) and the Status
// window (which needs the COUNTS). Extracted from
// CommitComposerViewModel so the two surfaces can never disagree
// about what counts as staged / unstaged / untracked / conflicted.

import GitCore

/// Per-entry classification: which buckets a porcelain-v2 entry
/// lands in. An ordinary entry can be both staged AND unstaged
/// (`MM`); the optionals carry the path for each bucket it occupies.
struct WorkingTreeBuckets {
    var staged: String?
    var unstaged: String?
    var untracked: String?
    var conflicted: String?
}

enum WorkingTreeClassifier {
    /// ADR 0070/0074's classification rules, verbatim:
    /// index-changed → staged; worktree-changed → unstaged; unmerged
    /// → conflicted; untracked → untracked; ignored entries are not
    /// surfaced (staging one is `git add -f` territory, a separate
    /// verb).
    static func classify(_ entry: Entry) -> WorkingTreeBuckets {
        var buckets = WorkingTreeBuckets()
        switch entry {
        case let .ordinary(ord):
            if ord.xy.index != .unmodified { buckets.staged = ord.path }
            if ord.xy.worktree != .unmodified { buckets.unstaged = ord.path }
        case let .renamed(ren):
            if ren.xy.index != .unmodified { buckets.staged = ren.path }
            if ren.xy.worktree != .unmodified { buckets.unstaged = ren.path }
        case let .unmerged(unm):
            buckets.conflicted = unm.path
        case let .untracked(path):
            buckets.untracked = path
        case .ignored:
            break
        }
        return buckets
    }
}
