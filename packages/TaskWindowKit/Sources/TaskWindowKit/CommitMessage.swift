// CommitMessage.swift
//
// Pure-data companions of `CommitComposerViewModel`: the two-field
// commit message draft and the boolean commit-option toggles. Split
// out of the view-model file to stay under SwiftLint's file_length
// cap as the ADR 0070 guard-rail surface grew.

import Foundation

/// The commit message the user is composing.
///
/// Two-field shape mirrors the natural commit-message split: subject
/// (first line, ~50 chars by Conventional Commits guidance) plus an
/// optional body. The VM joins them with a blank line when invoking
/// `git commit`.
public struct CommitMessage: Sendable, Equatable {
    /// First-line subject. Required for ``isReady``.
    public var subject: String

    /// Optional body — anything that goes after the blank line. Can
    /// be empty for one-line commits.
    public var body: String

    public init(subject: String = "", body: String = "") {
        self.subject = subject
        self.body = body
    }

    /// User-presentable validation message, or `nil` if the message
    /// is submittable. Subject must be non-empty after trimming.
    public var validationError: String? {
        if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a commit subject."
        }
        return nil
    }

    /// Convenience inverse of ``validationError``.
    public var isReady: Bool {
        validationError == nil
    }
}

/// Boolean toggles the UI exposes on the commit dialog.
public struct CommitOptions: Sendable, Equatable {
    /// `--amend` — replace the previous commit instead of creating a
    /// new one. The UI typically warns when the previous commit has
    /// been pushed (master plan §11.6); that warning is the shell's
    /// responsibility, not this VM's.
    public var amend: Bool

    /// `-s` / `--signoff` — append a `Signed-off-by:` trailer (DCO).
    public var signOff: Bool

    /// `-S` / `--gpg-sign` — sign the commit via the configured key
    /// (ADR 0044: SSH signing by default when keys are present).
    public var sign: Bool

    /// `--allow-empty` — permit a commit with no staged changes.
    /// Only useful for `--amend`-only message edits or empty merges;
    /// off by default so accidental no-op commits are rejected by
    /// git.
    public var allowEmpty: Bool

    public init(
        amend: Bool = false,
        signOff: Bool = false,
        sign: Bool = false,
        allowEmpty: Bool = false
    ) {
        self.amend = amend
        self.signOff = signOff
        self.sign = sign
        self.allowEmpty = allowEmpty
    }
}
