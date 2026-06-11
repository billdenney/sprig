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

    // MARK: - Cancellation (uniform across windows)

    /// "Switch cancelled.", "Clone cancelled.", … — pass the
    /// operation noun; nil yields the bare "Cancelled.".
    public static func cancelled(_ what: String? = nil) -> String {
        what.map { "\($0) cancelled." } ?? "Cancelled."
    }
}
