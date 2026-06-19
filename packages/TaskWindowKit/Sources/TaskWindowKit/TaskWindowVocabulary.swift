// TaskWindowVocabulary.swift
//
// ADR 0072 amendment — the task-window half of the vocabulary: every
// user-facing string the view models put into a
// `TaskWindowState.Failure` lives HERE, not inline at the call site,
// so copy review happens in one file and wording stays consistent
// across windows.
//
// Why this file is in TaskWindowKit and not next to
// `UIKitShared.StatusVocabulary`: `Failure.description` is built
// where the failure is constructed — inside the VMs — and the
// dependency arrow points UIKitShared → TaskWindowKit, so the VMs
// cannot reach StatusVocabulary. These strings are deliberately
// REGISTER-NEUTRAL: preconditions and validations are already plain
// imperatives ("Pick a branch to switch to first.") that read the
// same to a beginner and a power user, so the two-register split
// StatusVocabulary maintains for *outcomes* would add surface
// without adding meaning. If a register split ever becomes
// necessary, the typed accessors here are the seam.
//
// House style: short imperative sentences, trailing period, no git
// flags, `(git: …)` only where the term is the decision point (none
// qualify today).

import Foundation

/// Single string table for view-model failure / validation /
/// cancellation copy. Pure data — no formatting state, no git.
public enum TaskWindowVocabulary {
    // MARK: - Branch switcher (ADR 0069)

    public static let pickABranchFirst = "Pick a branch to switch to first."

    // MARK: - Commit composer (ADR 0070 / 0074)

    public static func resolveConflictedFirst(count: Int) -> String {
        "Resolve \(count) conflicted file(s) before committing."
    }

    public static let nothingToCommit =
        "Nothing to commit — stage changes, amend, or enable allow-empty."

    public static let enterCommitSubject = "Enter a commit subject."

    /// Region staging (ADR 0061): the selection touched no added or
    /// removed line, so there's nothing to stage.
    public static let selectionHasNoChange = "Select added or removed lines to stage."

    /// Region staging (ADR 0061): the selection would split a change to
    /// the last line of a file that has no trailing newline — stage the
    /// whole end-of-file change at once.
    public static let cannotSplitEndOfFile =
        "Stage the whole change to the last line — it can't be split because the file has no final newline."

    // MARK: - Clone dialog

    public static let enterRepositoryURL = "Enter a repository URL."
    public static let chooseTargetDirectory = "Choose a target directory."
    public static let shallowDepthMustBePositive =
        "Shallow-clone depth must be a positive integer."

    // MARK: - Merge conflict resolver (ADR 0034)

    public static func noConflictAtPath(_ path: String) -> String {
        "No conflict at path '\(path)'."
    }

    public static func pickASideFirst(_ path: String) -> String {
        "Pick a side for '\(path)' first."
    }

    public static let nothingToApply = "Nothing to apply — pick sides first."

    public static let noConflictsToFinalize = "No conflicts to finalize."

    public static func stillUnresolved(count: Int) -> String {
        "\(count) path(s) still unresolved."
    }

    public static let noMidstreamToFinalize =
        "No merge or rebase in progress to finalize — refresh first."

    public static let noMidstreamToAbort =
        "No merge or rebase in progress to abort — refresh first."

    // MARK: - Branch hygiene (ADR 0073)

    public static func notInStaleList(_ name: String) -> String {
        "\(name) is not in the stale-branch list; refresh first."
    }

    public static func useSafetyCopyCleanup(_ name: String, unpushed: Int) -> String {
        "\(name) has \(unpushed) unpushed commit(s); use the keep-a-safety-copy cleanup instead."
    }

    public static func switchAwayBeforeCleanup(_ name: String) -> String {
        "Switch away from \(name) before cleaning it up."
    }

    public static func refusedNotFullyMerged(_ name: String) -> String {
        "git refused: \(name) is not fully merged. Use the keep-a-safety-copy cleanup."
    }

    public static func checkedOutSwitchAway(_ name: String) -> String {
        "\(name) is checked out; switch away first."
    }

    // MARK: - Recover (ADR 0033 amendment)

    public static func notASnapshotRef(_ ref: String) -> String {
        "Not a Sprig safety copy: '\(ref)'."
    }

    public static func notABackupRef(_ ref: String) -> String {
        "Not a Sprig backup: '\(ref)'."
    }

    public static func recoveryRefMissing(_ ref: String) -> String {
        "That safety copy no longer exists: '\(ref)'. Refresh the list."
    }

    // MARK: - Stash browser (ADR 0079)

    public static func stashEntryGone(_ subject: String) -> String {
        "'\(subject)' is no longer in the set-aside list — the list has been refreshed."
    }

    public static func stashConflicted(_ subject: String) -> String {
        "Applying '\(subject)' hit conflicts — resolve them in your files; the set-aside copy is kept."
    }

    // MARK: - History editing (ADR 0082)

    public static let historyShared =
        "Those commits are already on the server — Sprig never rewrites shared history."

    public static let historyMidstream =
        "Finish or abort the merge or rebase in progress first."

    public static let historyStagedChanges =
        "You have staged changes — commit or unstage them first so they don't get mixed into the rewrite."

    public static let historyNoCommits = "No commits yet to edit."

    public static let historyDetached = "You're not on a branch — switch to a branch first."

    public static let historyNeedTwo = "Pick at least 2 commits to combine."

    public static let historyNotEnoughHistory = "There aren't that many commits to combine."

    // MARK: - Rebase plan (ADR 0083)

    public static let nothingToRebase =
        "Everything is already on the server — nothing to reorder."

    public static let invalidRebasePlan =
        "That plan doesn't match the commits to replay — refresh and try again."

    public static let rebaseConflictHandoff =
        "The replay hit conflicts — resolve them in the Conflicts window, or abort the rebase to put everything back."

    public static let rebaseDirtyWorktree =
        "You have unsaved changes — commit or set them aside first."

    // MARK: - Revert (ADR 0084)

    public static let revertConflicted =
        "Undoing that commit hit conflicts — resolve them in the Conflicts window, or abort the revert to put everything back."

    public static let revertMergeCommit = "That's a merge commit — undoing it isn't offered yet."

    public static let revertUnknownCommit = "That commit isn't in this repository."

    // MARK: - Stacked restack (ADR 0085)

    public static let restackNothingToRestack =
        "This branch is already on top of its parent — nothing to replay."

    public static let restackNoParentRecorded =
        "Record which branch this one is stacked on before restacking."

    public static let restackForkPointDiverged =
        "This branch has moved away from where it was stacked — re-record its parent before restacking."

    public static let restackStackCycle =
        "These branches are stacked in a loop — fix the recorded parents first."

    public static let restackNotCheckedOut =
        "Switch to that branch before restacking it."

    // MARK: - Selective sync (ADR 0089)

    /// The reassuring safety note shown in the folder picker.
    public static let selectiveSyncSafetyNote =
        "Unchecked folders are removed from this computer only — your history is "
            + "untouched, and they come back when you re-check them."

    /// Shown when the repo uses non-cone sparse-checkout patterns the
    /// cone-only picker won't rewrite.
    public static let selectiveSyncAdvancedPatterns =
        "This repository uses advanced sparse-checkout patterns — change them with the git command line."

    /// Fail-closed message: the named folders hold unsaved work and
    /// can't be set aside cleanly.
    public static func selectiveSyncBlocked(_ folders: [String]) -> String {
        let list = folders.joined(separator: ", ")
        return "These folders have unsaved work and can't be set aside cleanly: \(list). "
            + "Save or set the work aside first, or remove the folders anyway — "
            + "Sprig keeps a backup you can restore."
    }

    // MARK: - File history (ADR 0090)

    public static let restoreThisVersion = "Restore this version."

    public static func fileVersionRestored(_ path: String) -> String {
        "Restored — Sprig saved a copy of your current \(path) before restoring."
    }

    public static let fileVersionGone = "That version is no longer available — refresh the history."

    public static let fileVersionBinaryPreview =
        "This is a binary file — Sprig can restore it, but can't preview it here yet."

    // MARK: - Create release (ADR 0087)

    public static let releaseNeedsTag = "Enter a tag name for the release."

    public static let confirmReleaseFirst =
        "Review what will be published, then confirm to create the release."

    public static func releaseTagExists(_ name: String) -> String {
        "The tag \(name) already exists — pick a different name, or use the existing tag."
    }

    /// The release was published but some assets didn't upload. The
    /// release already exists on the forge, so the message says so (with
    /// its URL) and points to re-running publish to finish — never
    /// implies nothing happened.
    public static func releasePartialAssets(uploaded: Int, total: Int, url: String?) -> String {
        let location = url.map { " at \($0)" } ?? ""
        let failed = total - uploaded
        return "The release was published\(location), but \(failed) of \(total) file(s) didn't upload "
            + "— publish again to finish uploading them."
    }

    // MARK: - Agent review (ADR 0088)

    public static let agentReviewSplitNotTip =
        "Splitting is only offered for the most recent commit — that one is further back in history."

    public static let agentReviewSplitNoParent =
        "This commit can't be split here — it has no single earlier commit to peel its changes back onto."

    public static let agentReviewSplitDirty =
        "You have unsaved or staged changes — commit or set them aside first so the split starts clean."

    public static let agentReviewNothingToUndo =
        "Nothing to undo — Sprig hasn't split a commit in this window yet."

    // MARK: - Multi-repo roll-up (ADR 0094 Option 2)

    /// A repository in the roll-up finished without a readable result —
    /// shown for the (today unreachable) non-terminal per-repo state so
    /// the row is never silently dropped.
    public static let rollupRepoUnavailable =
        "Couldn't read this repository — refresh the list."

    // MARK: - Cancellation (uniform across windows)

    /// "Switch cancelled.", "Clone cancelled.", … — pass the
    /// operation noun; nil yields the bare "Cancelled.".
    public static func cancelled(_ what: String? = nil) -> String {
        what.map { "\($0) cancelled." } ?? "Cancelled."
    }
}
