// MergeApplyError.swift
//
// Typed-error vocabulary for the MergeConflictResolverViewModel's
// apply pipeline. Wrapped into ``TaskWindowState/failure`` for the
// VM's external surface; the typed cases exist so diagnostics
// tooling can categorize (each `underlyingTypeName` round-trips the
// case name).
//
// Extracted into its own file to keep the VM source under
// SwiftLint's file-length cap.

import Foundation

/// Errors thrown by the MergeConflictResolverViewModel's apply
/// pipeline.
public enum MergeApplyError: Error, Equatable, Sendable {
    /// Caller asked to apply a path whose choice is still
    /// ``ConflictedPathChoice/pending``.
    case pending(path: String)

    /// The requested stage isn't present in the conflict's entry
    /// (e.g. ``ConflictedPathChoice/base`` asked for an add/add
    /// conflict). The integer is the stage that was requested.
    case missingStage(path: String, stage: Int)

    /// ``ConflictedPathChoice/text(regions:)`` was chosen for a path
    /// whose ``ConflictKind`` isn't ``ConflictKind/text`` — per-region
    /// splicing only makes sense on line-mergeable text files.
    /// Callers should pick a whole-side choice
    /// (``ConflictedPathChoice/ours`` / ``theirs`` / ``base``) for
    /// binary / submodule / LFS-pointer / add-add conflicts instead.
    case textChoiceOnNonTextKind(path: String)

    /// A whole-side resolution wrote the LFS pointer to disk and
    /// staged it successfully, but `git lfs checkout` failed to
    /// materialize the binary into the working tree. Typically
    /// means git-lfs isn't installed (ADR 0029's "detect + one-click
    /// Homebrew install" surface should kick in here) or the LFS
    /// object isn't in cache and can't be fetched. The pointer and
    /// the index entry are correct regardless — the user can
    /// re-checkout later once LFS is healthy.
    case lfsMaterializeFailed(path: String, underlying: String)
}
